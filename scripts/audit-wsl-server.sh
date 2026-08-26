#!/usr/bin/env bash
set -u

command -v grep >/dev/null 2>&1 || { printf 'Required command is missing: grep\n' >&2; exit 127; }

status=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '[OK]   %s\n' "$label"
  else
    printf '[WARN] %s\n' "$label"
    status=1
  fi
}

printf 'WSL server audit for %s@%s\n' "$(id -un)" "$(hostname)"
printf 'Kernel: %s\n' "$(uname -sr)"
check 'Running under WSL' sh -c 'uname -r | grep -qi microsoft'
check 'systemd is PID 1' sh -c '[ "$(ps -p 1 -o comm=)" = systemd ]'
check 'Default IPv4 route exists' sh -c 'ip -4 route show default | grep -q .'
check 'Resolver has a nameserver' sh -c 'test -r /etc/resolv.conf && grep -Eq "^[[:space:]]*nameserver[[:space:]]+" /etc/resolv.conf'
check 'OpenSSH server is installed' command -v sshd
check 'ssh.service is active' systemctl is-active --quiet ssh.service
check 'Port 22 is listening' sh -c 'ss -ltn | grep -Eq "[.:]22[[:space:]]"'

printf '\nWSL addresses:\n'
ip -brief -4 address show 2>/dev/null || true
printf '\nDefault route:\n'
ip -4 route show default 2>/dev/null || true
printf '\nResolver:\n'
sed -n '/^[[:space:]]*\(nameserver\|search\)[[:space:]]/p' /etc/resolv.conf 2>/dev/null || true
printf '\nSSH policy files:\n'
grep -ERn '^[[:space:]]*(PermitRootLogin|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|AllowUsers|ClientAliveInterval|ClientAliveCountMax)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null || true

exit "$status"
