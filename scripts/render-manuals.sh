#!/usr/bin/env bash
set -Eeuo pipefail

command -v grep >/dev/null 2>&1 || { printf 'Required command is missing: grep\n' >&2; exit 127; }

wsl_user="$(id -un)"
windows_user=''
windows_hostname=''
distro=Ubuntu
ssh_port=2222
output_dir="$HOME/wsl-server-manuals"
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: render-manuals.sh --windows-user USER [options]

Options:
  --wsl-user USER          WSL SSH login user (default: current user)
  --windows-user USER      Windows host profile name (required)
  --windows-hostname NAME  Windows server hostname (auto-detected when possible)
  --distro NAME            WSL distribution name (default: Ubuntu)
  --ssh-port PORT          Windows LAN SSH port (default: 2222)
  --output-dir PATH        Output directory (default: ~/wsl-server-manuals)

Produces three standalone HTML files: a host administrator manual, a client
access manual, and an end-to-end project migration manual. The files contain
no passwords, private keys, or fixed LAN IPs.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --wsl-user) wsl_user="${2:-}"; shift 2 ;;
    --windows-user) windows_user="${2:-}"; shift 2 ;;
    --windows-hostname) windows_hostname="${2:-}"; shift 2 ;;
    --distro) distro="${2:-}"; shift 2 ;;
    --ssh-port) ssh_port="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! "$wsl_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  printf 'Invalid WSL user: %s\n' "$wsl_user" >&2
  exit 2
fi
if [[ ! "$windows_user" =~ ^[^/\\]+$ ]]; then
  printf 'A valid --windows-user is required.\n' >&2
  exit 2
fi
if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1024 ] || [ "$ssh_port" -gt 65535 ]; then
  printf 'SSH port must be between 1024 and 65535.\n' >&2
  exit 2
fi

if [ -z "$windows_hostname" ]; then
  powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  if [ -x "$powershell" ]; then
    windows_hostname="$($powershell -NoProfile -Command '[Environment]::MachineName' 2>/dev/null | tr -d '\r' | tail -n 1)"
  fi
fi
windows_hostname="${windows_hostname:-$(hostname)}"

escape_sed() { printf '%s' "$1" | sed 's/[&|]/\\&/g'; }
render() {
  local source="$1" target="$2"
  sed \
    -e "s|__WSL_USER__|$(escape_sed "$wsl_user")|g" \
    -e "s|__WINDOWS_USER__|$(escape_sed "$windows_user")|g" \
    -e "s|__DISTRO__|$(escape_sed "$distro")|g" \
    -e "s|__SSH_PORT__|$ssh_port|g" \
    -e "s|__WINDOWS_HOSTNAME__|$(escape_sed "$windows_hostname")|g" \
    -e "s|__GENERATED_DATE__|$(date +%F)|g" \
    "$source" > "$target"
}

install -d -m 0755 "$output_dir"
host_manual="$output_dir/wsl-server-host-manual.html"
client_manual="$output_dir/wsl-server-client-manual.html"
migration_manual="$output_dir/wsl-server-project-migration-manual.html"
render "$skill_dir/assets/workbench/public/admin-manual.html" "$host_manual"
render "$skill_dir/assets/workbench/public/client-access-manual.html" "$client_manual"
render "$skill_dir/assets/workbench/public/project-migration-manual.html" "$migration_manual"
chmod 0644 "$host_manual" "$client_manual" "$migration_manual"

if grep -En '__[A-Z0-9_]+__' "$host_manual" "$client_manual" "$migration_manual"; then
  printf 'Manual rendering left unresolved template values.\n' >&2
  exit 1
fi
printf 'Host manual: %s\n' "$host_manual"
printf 'Client manual: %s\n' "$client_manual"
printf 'Project migration manual: %s\n' "$migration_manual"
