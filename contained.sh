#!/usr/bin/env bash

set -Eeuo pipefail
export LANG=C LC_ALL=C
export PS4='#${BASH_SOURCE}:${LINENO} [${SHLVL},${BASH_SUBSHELL},$?]: '

# Program global variables
declare clean_up_tmp_chroot_dir='' clean_up_cgroup_name=''

log() {
  local -r fmt_str="$1"
  shift
  # shellcheck disable=SC2059
  printf "$0 ${FUNCNAME[1]}: $fmt_str\n" "${@}" >&2 || true
}

handle_exit() {
  local -r -i last_status="$?"
  log "Cleaning up before exiting with status %i" "$last_status"
  teardown_chroot "$clean_up_tmp_chroot_dir" || true
  teardown_cgroup "$clean_up_cgroup_name" || true
  log "Exiting now with status %i" "$last_status"
  exit "$last_status"
}
trap handle_exit INT HUP TERM QUIT EXIT

setup_chroot() {
  local -r -n setup_chroot_ro_paths="$1" setup_chroot_rw_paths="$2"
  local -r run_as_user="$3" run_as_group="$4"
  for path in "${setup_chroot_ro_paths[@]}" "${setup_chroot_rw_paths[@]}"; do
    if [ ! -r "$path" ]; then
      echo "Path \"$path\" does not exist. All paths exposed to the program must exist upfront." >&2
      exit 1
    fi
  done
  local chroot_dir='' abs_path=''
  chroot_dir="$(mktemp -d -p /tmp .contained-dot-sh-chroot-XXXXXXXXX)"
  log "Setting up chroot directory at %s" "$chroot_dir"
  # Correct the owner and permission of the temporary directory
  install -d -o "$run_as_user" -g "$run_as_group" -m 0500 "$chroot_dir"
  # Bind-mount read-only and read-writables paths
  for ro_path in "${setup_chroot_ro_paths[@]}"; do
    abs_path="$(cd -- "$ro_path" && pwd)"
    log "Making %s read-only" "$abs_path"
    mkdir -p "$chroot_dir/$abs_path"
    mount --make-rprivate --rbind -o ro "$abs_path" "$chroot_dir/$abs_path"
  done
  for rw_path in "${setup_chroot_rw_paths[@]}"; do
    abs_path="$(cd -- "$rw_path" && pwd)"
    log "Making %s read-writable" "$abs_path"
    mkdir -p "$chroot_dir/$abs_path"
    mount --make-rprivate --rbind -o rw "$abs_path" "$chroot_dir/$abs_path"
  done
  # Prepare pseudo file systems
  mkdir -p "$chroot_dir"/{dev,proc,sys}
  mount --make-rprivate -t devtmpfs -o ro none "$chroot_dir/dev"
  mount --make-rprivate -t proc -o ro none "$chroot_dir/proc"
  mount --make-rprivate -t sysfs -o ro none "$chroot_dir/sys/"
  # Create ephemeral data directories
  install -d -o root -g root -m 1777 "$chroot_dir/tmp"
  # Ensure the target program's user and group have full access to its own /run
  install -d -o "$run_as_user" -g "$run_as_group" -m 0755 "$chroot_dir/run"
  printf '%s' "$chroot_dir"
}

teardown_chroot() {
  local -r chroot_dir="$1"
  log "Tearing down chroot directory %s" "$chroot_dir"
  if [ ! -d "$chroot_dir" ]; then
    return 0
  fi
  # Un-mount all mount points underneath the chroot
  for _ in {1..5}; do
    # Allow interpretation of escaped sequences led by a backslash
    # For example a mount point with a space in its name shows up as "/mnt\040point" in /proc/mounts
    # shellcheck disable=SC2162
    while IFS=' ' read _ mount_point _; do
      if [[ "$mount_point" =~ ^$chroot_dir ]]; then
        log "Un-mounting %s" "$mount_point"
        umount -lfr "$mount_point" &>/dev/null || true
        rmdir "$mount_point" &>/dev/null || true
      fi
    done </proc/mounts
  done
  # Get rid of ephemeral data directories
  rm -rf "$chroot_dir"/{tmp,run} &>/dev/null || true
  # Get rid of remaining empty directories
  rmdir "$chroot_dir"/* &>/dev/null || true
  if ! rmdir "$chroot_dir"; then
    echo "There are files left over after cleaning up \"$chroot_dir\", please manually inspect them and then delete the directory."
  fi
}

setup_cgroup() {
  local -r -i pid_max="$1" cpu_pct="$2" mem_limit_mb="$3"
  local -r run_as_user="$4" run_as_group="$5"
  local -r cgroup_name="contained-dot-sh-$(uuidgen)"
  log "Creating a control group %s - limit number of processes: %d; limit CPU usage: %d %%; limit memory usage: %d MB" "$cgroup_name" "$pid_max" "$cpu_pct" "$mem_limit_mb"
  cgcreate -a "$run_as_user:$run_as_group" -t "$run_as_user:$run_as_group" -g "pids,cpu,cpuacct,memory:/$cgroup_name"
  cgset -r pids.max="$pid_max" "$cgroup_name"
  # In a second of CPU's time, the affected program may use up to Limit% * 1000000 / 100 microsconds.
  cgset -r cpu.cfs_period_us=1000000 "$cgroup_name"
  cgset -r cpu.cfs_quota_us=$((cpu_pct*1000000/100)) "$cgroup_name"
  cgset -r memory.limit_in_bytes=$((mem_limit_mb*1024*1024)) "$cgroup_name"
  printf '%s' "$cgroup_name"
}

teardown_cgroup() {
  local -r cgroup_name="$1"
  log "Tearing down control group %s" "$cgroup_name"
  cgdelete -g "pids,cpu,cpuacct,memory:/$cgroup_name" &>/dev/null || true
  return
}

print_usage() {
  local -i exit_status="$1"
  cat <<EOF
contained.sh - Rudimentary sandbox for running a program in its independent PID/hostname/mount namespaces, and with restricted access to file system, limited resource usage, optional privileged capabilities.

Usage:
$0 [options] -- program [arguments...]"

Options:
-h, --help                            Display the program print_usage information.
-r, --can-read=<path>                 Allow the program to read files and directories under this path. This option can be used multiple times.
-w, --can-write=<path>                Allow the program to read and write files and directories under this path. This option can be used multiple times.
(Only the paths specified in -r and -w will be visible to the program)

-p, --proc-max=<number>               Allow the program to spawn at most this number processes.
-c, --cpu-pct=<number>                Allow the program to use this many % of CPU's time (up to 100%).
-m, --mem-limit-mb=<number-of-MBytes> Allow the program to consume this much system memory.

-u, --user=<name-or-id>               Run the program with this substitute user.
-g, --group=<name-or-id>              Run the program with this substitute group.

--cap=<capability-name>               Grant this capability to the program. This option can be used multiple times.

Example: run nginx web server as an unprivileged user, while restricting its system resource usage, and only allow write-access to its log directory:

  sudo ./contained.sh \
    (Restrict access to file system)
    --can-read /bin --can-read /etc --can-read /lib --can-read /lib64 --can-read /sbin --can-read /usr --can-read /var \
    --can-write /var/log/nginx \
    (Restrict system resource usage)
    --proc-max 30 --cpu-pct 10 --mem-limit-mb 32 \
    (Run as a regular user)
    --user www-data --group nogroup \
    (Permit listening on privileged port)
    --cap net_bind_service \
    (Start nginx)
    -- /usr/sbin/nginx -g 'daemon off;'
EOF
  exit "$exit_status"
}


main() {
  local -a read_only_paths=() read_write_paths=() capabilities=()
  local -i pid_max=100 cpu_pct=10 mem_limit_mb=128
  local run_as_user='nobody' run_as_group='nogroup'

  while true; do
    if [ $# -eq 0 ]; then
      break
    fi
    local arg_val=''
    case "$1" in
      -h|--help)
        print_usage 0
        ;;
      --can-read=*) arg_val="${1#*=}" ;&
      -r|--can-read)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        read_only_paths+=("$arg_val")
        ;;
      --can-write=*) arg_val="${1#*=}" ;&
      -w|--can-write)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        read_write_paths+=("$arg_val")
        ;;
      --proc-max=*) arg_val="${1#*=}" ;&
      -p|--proc-max)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        pid_max="$arg_val"
        ;;
      --cpu-pct=*) arg_val="${1#*=}" ;&
      -c|--cpu-pct)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        cpu_pct="$arg_val"
        ;;
      --mem-limit-mb=*) arg_val="${1#*=}" ;&
      -m|--mem-limit-mb)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        mem_limit_mb="$arg_val"
        ;;
      --user=*) arg_val="${1#*=}" ;&
      -u|--user)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        run_as_user="$arg_val"
        ;;
      --group=*) arg_val="${1#*=}" ;&
      -g|--group)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        run_as_group="$arg_val"
        ;;
      --cap=*) arg_val="${1#*=}" ;&
      --cap)
        if [ ! "$arg_val" ]; then
          shift
          if [ $# -ge 1 ]; then arg_val="$1"; else print_usage 1; fi
        fi
        capabilities+=("$arg_val")
        ;;
      --)
        shift
        break
        ;;
      *)
        if [ $# -ge 1 ]; then
          echo "Unrecognised program arguments: $1" >&2
          print_usage 1
        fi
        ;;
    esac
    shift
  done

  local -a prog_with_args=("${@}")
  if [ ${#prog_with_args[@]} -eq 0 ]; then
    echo 'Please specify the program and its arguments that will run in the restricted execution environment.' >&2
    exit 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    echo 'Please run this program as the root user, as the restricted execution environment requires root privileges to setup.' >&2
    exit 1
  fi
  for prog in mount install chroot cgcreate unshare uuidgen setpriv; do
    if ! command -v "$prog" &>/dev/null; then
      echo 'Please install the program %s on the system, it is a dependency of this program.' "$prog" >&2
      exit 1
    fi
  done

  tmp_chroot_dir="$(setup_chroot read_only_paths read_write_paths "$run_as_user" "$run_as_group")"
  clean_up_tmp_chroot_dir="$tmp_chroot_dir"
  tmp_cgroup_name="$(setup_cgroup "$pid_max" "$cpu_pct" "$mem_limit_mb" "$run_as_user" "$run_as_group")"
  clean_up_cgroup_name="$tmp_cgroup_name"

  # Remove all capabilities and grant the desired capabilities to the process
  local setpriv_caps='-all'
  for ((i=0; i<${#capabilities[@]} ;i++)); do
    setpriv_caps="$setpriv_caps,+${capabilities[$i]}"
  done

  log 'About to start program \"%s\" using command arguments \"%s\" as user \"%s\" and group \"%s\", and with additional capabilities \"%s\"' \
    "$(command -v "${prog_with_args[0]}")" "${prog_with_args[*]:1}" "$run_as_user" "$run_as_group" "${capabilities[*]}"
  /usr/bin/cgexec -g pids,cpu,cpuacct,memory:/"$tmp_cgroup_name" \
    /usr/bin/unshare -m --uts --pid --fork --kill-child --mount-proc -R "$tmp_chroot_dir" \
    /usr/bin/setpriv --reset-env --no-new-privs --inh-caps "$setpriv_caps" --ambient-caps "$setpriv_caps" --clear-groups --reuid "$run_as_user" --regid "$run_as_group" \
    "${prog_with_args[@]}"
}

main "${@:-}"
