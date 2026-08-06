#!/usr/bin/env bash
set -Eeuo pipefail

target_user="${SUDO_USER:-${USER:-}}"
password_auth=yes
config_file=/etc/ssh/sshd_config.d/99-wsl-server.conf
dry_run=0

usage() {
  cat <<'EOF'
Usage: configure-wsl-sshd.sh [--user USER] [--password-auth yes|no] [--dry-run]

Installs OpenSSH Server and writes a restrictive sshd drop-in. Public-key
authentication remains enabled. Root and keyboard-interactive login are denied.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) target_user="${2:-}"; shift 2 ;;
    --password-auth) password_auth="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! "$target_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  printf 'Invalid or missing Linux user: %s\n' "$target_user" >&2
  exit 2
fi
if [[ "$password_auth" != yes && "$password_auth" != no ]]; then
  printf -- '--password-auth must be yes or no.\n' >&2
  exit 2
fi

render() {
  cat <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $password_auth
KbdInteractiveAuthentication no
AllowUsers $target_user
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
}

if [ "$dry_run" -eq 1 ]; then render; exit 0; fi
if [ "$(id -u)" -ne 0 ]; then
  printf 'Run this script with sudo. Enter the password only in your terminal.\n' >&2
  exit 1
fi
if ! id "$target_user" >/dev/null 2>&1; then
  printf 'Linux user does not exist: %s\n' "$target_user" >&2
  exit 1
fi
if [ "$(ps -p 1 -o comm=)" != systemd ]; then
  printf 'systemd is not PID 1. Configure /etc/wsl.conf and restart WSL first.\n' >&2
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
tmp_file="$(mktemp "${TMPDIR:-/tmp}/wsl-sshd.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT
render > "$tmp_file"
if [ -e "$config_file" ]; then
  cp --preserve=all "$config_file" "$config_file.backup.$(date +%Y%m%d%H%M%S)"
fi
install -m 0644 "$tmp_file" "$config_file"
sshd -t
systemctl enable --now ssh.service
printf 'Configured OpenSSH for user %s (password authentication: %s).\n' "$target_user" "$password_auth"

