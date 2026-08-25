#!/usr/bin/env bash
set -Eeuo pipefail

registry=''
install_dir="${HOME}/wsl-server/project-sync"
state_dir="${HOME}/.local/state/wsl-project-sync"
render_only=''
skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: install-project-sync.sh --registry ABS_PATH [--install-dir ABS_PATH] \
  [--state-dir ABS_PATH] [--render-only OUTPUT_DIR]

Renders or installs the project-sync script and user units. Installation links
the units and reloads the user manager, but never enables or starts the timer.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry) registry="${2:-}"; shift 2 ;;
    --install-dir) install_dir="${2:-}"; shift 2 ;;
    --state-dir) state_dir="${2:-}"; shift 2 ;;
    --render-only) render_only="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

fail() { printf '%s\n' "$1" >&2; exit 2; }
escape_sed() { printf '%s' "$1" | sed 's/[&|]/\\&/g'; }
safe_service_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._+@/-]+$ ]] &&
    [[ "$1" != / && "$1" != *//* && "$1" != */./* && "$1" != */. &&
       "$1" != */../* && "$1" != */.. ]]
}
for path in "$registry" "$install_dir" "$state_dir"; do
  safe_service_path "$path" || fail 'All configured paths must be safe absolute paths.'
done
[ -f "$registry" ] && [ ! -L "$registry" ] || fail 'Registry must be a regular file.'
if [ -n "$render_only" ]; then
  [[ "$render_only" == /* ]] || fail '--render-only must be absolute.'
  [ ! -e "$render_only" ] && [ ! -L "$render_only" ] || fail '--render-only destination must not exist.'
fi

python3 "$skill_dir/assets/project-sync/sync-projects.py" \
  --registry "$registry" --state-dir "$state_dir" --validate

stage="$(mktemp -d "${TMPDIR:-/tmp}/wsl-project-sync.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
install -d -m 0755 "$stage"
install -m 0755 "$skill_dir/assets/project-sync/sync-projects.py" "$stage/sync-projects.py"
install -m 0644 "$skill_dir/assets/project-sync/wsl-project-sync.timer" "$stage/wsl-project-sync.timer"

read_write_paths="$(python3 - "$registry" "$state_dir" "$skill_dir/assets/project-sync/sync-projects.py" <<'PY'
import importlib.util
import pathlib
import sys

registry = pathlib.Path(sys.argv[1])
state_dir = pathlib.Path(sys.argv[2])
sync_script = pathlib.Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("project_sync", sync_script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
paths = {state_dir}
for project in module.load_projects(registry):
    if not project["enabled"]:
        continue
    paths.add(pathlib.Path(project["source_path"]) / ".git")
    if project["sync_policy"] == "stage-release":
        paths.add(pathlib.Path(project["deploy_root"]) / "releases")
print(" ".join(f"-{path}" for path in sorted(paths, key=str)))
PY
)"
sed \
  -e "s|__INSTALL_DIR__|$(escape_sed "$install_dir")|g" \
  -e "s|__REGISTRY_PATH__|$(escape_sed "$registry")|g" \
  -e "s|__STATE_DIR__|$(escape_sed "$state_dir")|g" \
  -e "s|__READ_WRITE_PATHS__|$(escape_sed "$read_write_paths")|g" \
  "$skill_dir/assets/project-sync/wsl-project-sync.service.in" > "$stage/wsl-project-sync.service"

if rg -n '__[A-Z0-9_]+__' "$stage"; then fail 'Rendered output has unresolved placeholders.'; fi

destination="${render_only:-$install_dir}"
[ ! -e "$destination" ] && [ ! -L "$destination" ] || fail 'Install destination must not exist.'
if [ -z "$render_only" ]; then
  unit_dir="${HOME}/.config/systemd/user"
  for unit in wsl-project-sync.service wsl-project-sync.timer; do
    [ ! -e "$unit_dir/$unit" ] && [ ! -L "$unit_dir/$unit" ] || fail "Unit already exists: $unit"
  done
fi
install -d -m 0755 "$destination"
cp -R "$stage/." "$destination/"
chmod 0755 "$destination/sync-projects.py"

if [ -n "$render_only" ]; then
  printf 'Rendered project sync layer without enabling it: %s\n' "$destination"
  exit 0
fi

install -d -m 0755 "$unit_dir"
install -d -m 0700 "$state_dir"
for unit in wsl-project-sync.service wsl-project-sync.timer; do
  ln -s "$install_dir/$unit" "$unit_dir/$unit"
done
systemctl --user daemon-reload
printf 'Installed project sync units without enabling or starting the timer: %s\n' "$install_dir"
