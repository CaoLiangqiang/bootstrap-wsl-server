#!/usr/bin/env bash
set -u

expected_user="${1:-$(id -un)}"
config_file="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/99-wsl-server.conf}"
failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; failures=$((failures + 1)); }
run_check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

run_check 'systemd active' sh -c '[ "$(ps -p 1 -o comm=)" = systemd ]'
run_check 'default IPv4 route' sh -c 'ip -4 route show default | grep -q .'
run_check 'DNS resolver' sh -c 'test -r /etc/resolv.conf && grep -Eq "^[[:space:]]*nameserver[[:space:]]+" /etc/resolv.conf'
run_check 'ssh.service active' systemctl is-active --quiet ssh.service
run_check 'TCP 22 listening' sh -c 'ss -ltn | grep -Eq "[.:]22[[:space:]]"'
run_check 'authorized_keys directory mode 700' sh -c '[ ! -d "$HOME/.ssh" ] || [ "$(stat -c %a "$HOME/.ssh")" = 700 ]'
run_check 'authorized_keys file mode 600' sh -c '[ ! -f "$HOME/.ssh/authorized_keys" ] || [ "$(stat -c %a "$HOME/.ssh/authorized_keys")" = 600 ]'

if [ -r "$config_file" ]; then
  run_check 'root login denied' grep -Eq '^PermitRootLogin[[:space:]]+no$' "$config_file"
  run_check 'public-key login enabled' grep -Eq '^PubkeyAuthentication[[:space:]]+yes$' "$config_file"
  run_check "AllowUsers contains $expected_user" grep -Eq "^AllowUsers[[:space:]]+.*(^|[[:space:]])${expected_user}([[:space:]]|$)" "$config_file"
else
  fail 'managed sshd drop-in exists'
fi

if [ "$failures" -gt 0 ]; then
  printf '\nVerification failed: %d check(s).\n' "$failures"
  exit 1
fi
printf '\nWSL SSH layer is healthy. Verify Windows portproxy and firewall separately.\n'
