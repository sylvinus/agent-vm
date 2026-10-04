#!/bin/bash
# Control for fs_suite.py: same sshfs options, served by OpenSSH's sftp-server
# instead of sshocker's rooted server. A DIFF here is sshfs or SFTP v3, not sshocker.
#   openssh_harness.sh mount <hostdir> <mountpoint>
set -euo pipefail
[[ "${1:-}" == mount ]] || { echo "usage: $0 mount <hostdir> <mountpoint>" >&2; exit 2; }
host="$2" mnt="$3"
server="${SFTP_SERVER:-/usr/lib/openssh/sftp-server}"
fifo="$(mktemp -u)"
mkfifo "$fifo"
trap 'rm -f "$fifo"' EXIT
cd "$host"
"$server" -e < "$fifo" | sshfs ":$host" "$mnt" -o slave -o allow_other -o no_contain_symlinks -f > "$fifo"
