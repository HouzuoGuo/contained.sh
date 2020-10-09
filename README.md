# contained.sh
```
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
```
