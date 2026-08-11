#!/usr/bin/env bash
set -Eeuo pipefail

app_id=''
app_name=''
service_unit=''
app_port=''
health_path=''
gateway_hostname=''
gateway_port=''
caddy_bin=''
install_dir="${HOME}/wsl-server/apps"
render_only=''
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: install-webui-apps.sh --app-id ID --app-name NAME --service-unit UNIT \
  --app-port PORT --health-path PATH --gateway-hostname HOST \
  --gateway-port PORT --caddy-bin ABS_PATH [--install-dir ABS_PATH] \
  [--render-only OUTPUT_DIR]

Renders the optional Phase 2b WebUI operations layer. Normal installation links
only its own user units and does not enable, start, stop, or restart any unit.
Render-only mode writes only OUTPUT_DIR and performs no live-system discovery.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-id) app_id="${2:-}"; shift 2 ;;
    --app-name) app_name="${2:-}"; shift 2 ;;
    --service-unit) service_unit="${2:-}"; shift 2 ;;
    --app-port) app_port="${2:-}"; shift 2 ;;
    --health-path) health_path="${2:-}"; shift 2 ;;
    --gateway-hostname) gateway_hostname="${2:-}"; shift 2 ;;
    --gateway-port) gateway_port="${2:-}"; shift 2 ;;
    --caddy-bin) caddy_bin="${2:-}"; shift 2 ;;
    --install-dir) install_dir="${2:-}"; shift 2 ;;
    --render-only) render_only="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

fail() { printf '%s\n' "$1" >&2; exit 2; }
[[ "$app_id" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || fail 'Invalid --app-id.'
[[ "$app_id" != gateway && "$app_id" != workbench ]] || fail 'Reserved --app-id.'
[ -n "$app_name" ] && [ "${#app_name}" -le 80 ] || fail 'Invalid --app-name.'
[[ "$app_name" != *$'\n'* && "$app_name" != *$'\r'* ]] || fail 'Invalid --app-name.'
[[ "$service_unit" =~ ^[A-Za-z0-9_.:@-]+\.service$ ]] || fail 'Invalid --service-unit.'
[[ "$app_port" =~ ^[0-9]+$ ]] && (( app_port >= 1024 && app_port <= 65535 )) || fail 'Invalid --app-port.'
(( app_port != 4173 )) || fail 'Port 4173 is reserved for the loopback-only workbench.'
[[ "$health_path" == /* && "$health_path" != //* && "$health_path" != *\\* && "$health_path" != *\?* && "$health_path" != *\#* ]] || fail 'Invalid --health-path.'
[[ "$health_path" != *[[:space:]]* ]] || fail 'Invalid --health-path.'
[[ "$gateway_hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]] || fail 'Invalid --gateway-hostname.'
[ "${#gateway_hostname}" -le 253 ] && [ "$gateway_hostname" != localhost ] || fail 'Invalid --gateway-hostname.'
[[ "$gateway_hostname" != +([0-9.]) ]] || fail 'Gateway hostname must not be an IP address.'
[[ "$gateway_port" =~ ^[0-9]+$ ]] && (( gateway_port >= 1024 && gateway_port <= 65535 )) || fail 'Invalid --gateway-port.'
(( gateway_port != app_port && gateway_port != 4173 )) || fail 'Gateway port conflicts with another reserved port.'
[[ "$caddy_bin" == /* && "$caddy_bin" != *[[:space:]]* ]] || fail '--caddy-bin must be an absolute path without whitespace.'
[[ "$install_dir" == /* && "$install_dir" != *[[:space:]]* ]] || fail '--install-dir must be an absolute path without whitespace.'
[ ! -L "$install_dir" ] || fail '--install-dir must not be a symlink.'
if [ -n "$render_only" ]; then
  [[ "$render_only" == /* ]] || fail '--render-only must be an absolute path.'
  [ ! -L "$render_only" ] || fail '--render-only must not be a symlink.'
fi

if [ -n "$render_only" ]; then
  stage="$(mktemp -d "${TMPDIR:-/tmp}/wsl-webui.XXXXXX")"
else
  install_parent="$(dirname "$install_dir")"
  [ -d "$install_parent" ] && [ ! -L "$install_parent" ] ||
    fail "The install parent must already be a regular directory: $install_parent"
  stage="$(mktemp -d "$install_parent/.wsl-webui.XXXXXX")"
fi
trap 'rm -rf "$stage"' EXIT
cp -R "$skill_dir/assets/webui/." "$stage/"
find "$stage" -type f -name '*.py[co]' -delete
find "$stage" -depth -type d -name __pycache__ -delete

python3 - "$stage" "$install_dir" "$app_id" "$app_name" "$service_unit" \
  "$app_port" "$health_path" "$gateway_hostname" "$gateway_port" "$caddy_bin" <<'PY'
import json
import pathlib
import sys

(stage, install_dir, app_id, app_name, service_unit, app_port, health_path,
 gateway_hostname, gateway_port, caddy_bin) = sys.argv[1:]
root = pathlib.Path(stage)
replacements = {
    "__INSTALL_DIR__": install_dir,
    "__APP_ID__": app_id,
    "__APP_NAME_JSON__": json.dumps(app_name, ensure_ascii=True)[1:-1],
    "__APP_NAME_TEXT__": app_name,
    "__SERVICE_UNIT__": service_unit,
    "__APP_PORT__": app_port,
    "__HEALTH_PATH_JSON__": json.dumps(health_path, ensure_ascii=True)[1:-1],
    "__HEALTH_PATH_TEXT__": health_path,
    "__GATEWAY_HOSTNAME__": gateway_hostname,
    "__GATEWAY_PORT__": gateway_port,
    "__CADDY_BIN__": caddy_bin,
}
for source in sorted(root.rglob("*.in")):
    text = source.read_text(encoding="utf-8")
    for marker, value in replacements.items():
        text = text.replace(marker, value)
    target = source.with_suffix("")
    target.write_text(text, encoding="utf-8")
    source.unlink()
PY

chmod 0755 "$stage/scripts/check-app-health.py"
find "$stage" -type f ! -path "$stage/scripts/check-app-health.py" -exec chmod 0644 {} +
if grep -R -n -E '__[A-Z0-9_]+__' "$stage"; then
  fail 'Rendered output contains unresolved placeholders.'
fi
python3 - "$stage/scripts/check-app-health.py" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY
python3 "$stage/scripts/check-app-health.py" --registry "$stage/registry.json" --validate

publish_tree() {
  local destination="$1"
  if [ -e "$destination" ] && [ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    printf 'Destination is not empty: %s\n' "$destination" >&2
    return 2
  fi
  install -d -m 0755 "$destination"
  cp -R "$stage/." "$destination/"
  find "$destination" -type d -exec chmod 0755 {} +
  find "$destination" -type f -exec chmod 0644 {} +
  chmod 0755 "$destination/scripts/check-app-health.py"
}

if [ -n "$render_only" ]; then
  publish_tree "$render_only"
  printf 'Rendered optional WebUI layer: %s\n' "$render_only"
  exit 0
fi

[ -x "$caddy_bin" ] || fail 'The configured Caddy binary is not executable.'
caddy_version="$($caddy_bin version 2>/dev/null | head -n 1)" ||
  fail 'Failed to read the Caddy version.'
if [[ ! "$caddy_version" =~ ^v?([0-9]+)\.([0-9]+)\. ]]; then
  fail 'Unable to parse the Caddy version.'
fi
if (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 6) )); then
  fail 'Caddy 2.6 or newer is required.'
fi
GATEWAY_USERNAME=validation \
GATEWAY_PASSWORD_HASH='$2a$14$00000000000000000000000000000000000000000000000000000' \
  "$caddy_bin" adapt --config "$stage/gateway/Caddyfile" \
    --adapter caddyfile >/dev/null || fail 'Rendered Caddyfile is invalid.'
unit_dir="${HOME}/.config/systemd/user"
for unit_name in \
  wsl-app-health@.service \
  wsl-app-health@.timer \
  webui-gateway.service; do
  [ ! -e "$unit_dir/$unit_name" ] && [ ! -L "$unit_dir/$unit_name" ] ||
    fail "User unit already exists: $unit_dir/$unit_name"
done

[ ! -e "$install_dir" ] && [ ! -L "$install_dir" ] ||
  fail "The install destination must not already exist: $install_dir"

private_dirs=(
  "${HOME}/.config/webui-gateway"
  "${HOME}/.local/share/caddy"
  "${HOME}/.local/state/webui-gateway"
)
for directory in "$unit_dir" "${private_dirs[@]}"; do
  if [ -e "$directory" ] || [ -L "$directory" ]; then
    [ -d "$directory" ] && [ ! -L "$directory" ] ||
      fail "Required directory is not a regular directory: $directory"
  fi
done
for directory in "${private_dirs[@]}"; do
  if [ -d "$directory" ] && (( 8#$(stat -c %a "$directory") & 8#077 )); then
    fail "Private directory permissions are too broad: $directory"
  fi
done

created_dirs=()
created_links=()
install_dir_claimed=false
rollback_live_install() {
  local exit_code=$?
  trap - ERR
  set +e
  for link in "${created_links[@]}"; do
    unlink "$link"
  done
  if $install_dir_claimed && [ -d "$install_dir" ] && [ ! -L "$install_dir" ]; then
    mv -T "$install_dir" "$stage"
  fi
  for (( index=${#created_dirs[@]} - 1; index >= 0; index-- )); do
    rmdir "${created_dirs[index]}"
  done
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap rollback_live_install ERR

if [ ! -d "$unit_dir" ]; then
  install -d -m 0755 "$unit_dir"
  created_dirs+=("$unit_dir")
fi
for directory in "${private_dirs[@]}"; do
  if [ ! -d "$directory" ]; then
    install -d -m 0700 "$directory"
    created_dirs+=("$directory")
  fi
done

mv -T "$stage" "$install_dir"
install_dir_claimed=true
ln -s "$install_dir/systemd/wsl-app-health@.service" "$unit_dir/wsl-app-health@.service"
created_links+=("$unit_dir/wsl-app-health@.service")
ln -s "$install_dir/systemd/wsl-app-health@.timer" "$unit_dir/wsl-app-health@.timer"
created_links+=("$unit_dir/wsl-app-health@.timer")
ln -s "$install_dir/gateway/webui-gateway.service" "$unit_dir/webui-gateway.service"
created_links+=("$unit_dir/webui-gateway.service")
systemctl --user daemon-reload
trap - ERR
printf 'Installed optional WebUI layer without starting any service or timer: %s\n' "$install_dir"
