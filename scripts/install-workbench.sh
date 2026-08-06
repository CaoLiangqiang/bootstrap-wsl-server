#!/usr/bin/env bash
set -Eeuo pipefail

windows_user=''
windows_hostname=''
distro=Ubuntu
ssh_port=2222
install_dir="$HOME/.local/share/wsl-server-workbench"
render_only=''
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: install-workbench.sh --windows-user USER [--windows-hostname NAME] [--distro NAME] [--ssh-port PORT] [--install-dir PATH] [--render-only PATH]

Installs the loopback-only dashboard, its five-minute health timer, and Windows
management scripts. Requires Node.js and a mounted Windows C: drive.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --windows-user) windows_user="${2:-}"; shift 2 ;;
    --windows-hostname) windows_hostname="${2:-}"; shift 2 ;;
    --distro) distro="${2:-}"; shift 2 ;;
    --ssh-port) ssh_port="${2:-}"; shift 2 ;;
    --install-dir) install_dir="${2:-}"; shift 2 ;;
    --render-only) render_only="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ ! "$windows_user" =~ ^[^/\\]+$ ]]; then
  printf 'A valid --windows-user is required.\n' >&2
  exit 2
fi
if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1024 ] || [ "$ssh_port" -gt 65535 ]; then
  printf 'SSH port must be between 1024 and 65535.\n' >&2
  exit 2
fi
command -v node >/dev/null || {
  printf 'Node.js is required. Install it from Ubuntu before installing the workbench.\n' >&2
  exit 1
}
windows_root="/mnt/c/Users/$windows_user"
if [ -z "$render_only" ] && [ ! -d "$windows_root" ]; then
  printf 'Windows profile is not mounted at %s\n' "$windows_root" >&2
  exit 1
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/wsl-workbench.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R "$skill_dir/assets/workbench/." "$stage/"

escape_sed() { printf '%s' "$1" | sed 's/[&|]/\\&/g'; }
wsl_user="$(id -un)"
if [ -z "$windows_hostname" ]; then
  powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  if [ -x "$powershell" ]; then
    windows_hostname="$($powershell -NoProfile -Command '[Environment]::MachineName' 2>/dev/null | tr -d '\r' | tail -n 1)"
  fi
fi
windows_hostname="${windows_hostname:-$(hostname)}"
for file in $(find "$stage" -type f \( -name '*.js' -o -name '*.html' -o -name '*.ps1' -o -name '*.json' \)); do
  sed -i \
    -e "s|__WSL_USER__|$(escape_sed "$wsl_user")|g" \
    -e "s|__WINDOWS_USER__|$(escape_sed "$windows_user")|g" \
    -e "s|__DISTRO__|$(escape_sed "$distro")|g" \
    -e "s|__SSH_PORT__|$ssh_port|g" \
    -e "s|__WINDOWS_HOSTNAME__|$(escape_sed "$windows_hostname")|g" "$file"
done

if [ -n "$render_only" ]; then
  install -d -m 0755 "$render_only"
  cp -R "$stage/." "$render_only/"
  printf 'Rendered workbench template: %s\n' "$render_only"
  exit 0
fi

install -d -m 0755 "$install_dir"
cp -R "$stage/." "$install_dir/"
install -d -m 0755 "$windows_root/.wsl-server"
install -m 0644 "$skill_dir/scripts/Configure-WslSshLan.ps1" "$windows_root/.wsl-server/Configure-WslSshLan.ps1"

unit_dir="$HOME/.config/systemd/user"
install -d -m 0755 "$unit_dir"
cat > "$unit_dir/wsl-server-workbench.service" <<EOF
[Unit]
Description=WSL Server Workbench
After=network.target

[Service]
Type=simple
WorkingDirectory=$install_dir
ExecStart=$(command -v node) $install_dir/server.js
Restart=on-failure
RestartSec=3
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF
cat > "$unit_dir/wsl-server-workbench-health.service" <<EOF
[Unit]
Description=WSL Server Workbench periodic health check
After=wsl-server-workbench.service
Requires=wsl-server-workbench.service

[Service]
Type=oneshot
WorkingDirectory=$install_dir
ExecStart=$(command -v node) $install_dir/scripts/health-check.js
Environment=NODE_ENV=production
PrivateTmp=true
NoNewPrivileges=true
EOF
cat > "$unit_dir/wsl-server-workbench-health.timer" <<'EOF'
[Unit]
Description=Run WSL Server Workbench health check every five minutes

[Timer]
OnBootSec=90s
OnUnitActiveSec=5min
AccuracySec=15s
Persistent=true
Unit=wsl-server-workbench-health.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now wsl-server-workbench.service wsl-server-workbench-health.timer
printf 'Workbench: http://127.0.0.1:4173\n'
printf 'Windows LAN script: C:\\Users\\%s\\.wsl-server\\Configure-WslSshLan.ps1\n' "$windows_user"
