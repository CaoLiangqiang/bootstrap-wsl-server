#!/usr/bin/env bash
set -Eeuo pipefail

deploy_root=''
release_id=''
timeout_seconds=30
dry_run=false
services=()
health_urls=()
temporary_link=''
systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"

usage() {
  cat <<'EOF'
Usage: switch-versioned-release.sh --deploy-root ABS_PATH --release-id ID \
  --service UNIT [--service UNIT ...] \
  --health-url http://127.0.0.1:PORT/PATH [--health-url URL ...] \
  [--timeout SECONDS] [--dry-run]

Validates an already staged release, atomically switches DEPLOY_ROOT/current,
restarts only the named user services, and waits for every loopback health URL.
If verification fails, the former current target is restored and restarted.
The script does not stage files, edit the registry, or remove old releases.
EOF
}

fail() { printf '%s\n' "$1" >&2; exit 2; }
user_systemctl() { "$systemctl_bin" --user "$@"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --deploy-root) deploy_root="${2:-}"; shift 2 ;;
    --release-id) release_id="${2:-}"; shift 2 ;;
    --service) services+=("${2:-}"); shift 2 ;;
    --health-url) health_urls+=("${2:-}"); shift 2 ;;
    --timeout) timeout_seconds="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$deploy_root" == /* && "$deploy_root" != *[[:space:]]* ]] ||
  fail '--deploy-root must be an absolute path without whitespace.'
[[ "$release_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || fail 'Invalid --release-id.'
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds >= 1 && timeout_seconds <= 300 )) ||
  fail '--timeout must be from 1 to 300 seconds.'
((${#services[@]} > 0)) || fail 'At least one --service is required.'
((${#health_urls[@]} > 0)) || fail 'At least one --health-url is required.'

[ -d "$deploy_root" ] && [ ! -L "$deploy_root" ] ||
  fail "Deploy root must be a regular directory: $deploy_root"
release_path="$deploy_root/releases/$release_id"
[ -d "$release_path" ] && [ ! -L "$release_path" ] ||
  fail "Release must be a regular directory: $release_path"
[ -f "$release_path/.release.json" ] && [ ! -L "$release_path/.release.json" ] ||
  fail "Release metadata is missing or unsafe: $release_path/.release.json"
[ -L "$deploy_root/current" ] || fail "Current must already be a symlink: $deploy_root/current"

python3 - "$release_path/.release.json" "$release_id" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
if document.get("release_id") != sys.argv[2]:
    raise SystemExit("release metadata does not match --release-id")
commit = document.get("git_commit")
if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
    raise SystemExit("release metadata has an invalid git_commit")
PY

for unit in "${services[@]}"; do
  [[ "$unit" =~ ^[A-Za-z0-9_.:@-]+\.service$ ]] || fail "Invalid service unit: $unit"
done
for url in "${health_urls[@]}"; do
  [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/[^[:space:]]*$ ]] ||
    fail "Health URL must use loopback HTTP without credentials: $url"
done

current_target="$(readlink -f "$deploy_root/current")"
case "$current_target" in
  "$deploy_root"/releases/*) ;;
  *) fail "Current resolves outside the release directory: $current_target" ;;
esac
[ "$current_target" != "$release_path" ] || fail "Release is already current: $release_id"

if $dry_run; then
  printf 'VERSIONED_RELEASE_DRY_RUN_OK current=%s target=%s\n' "$current_target" "$release_path"
  exit 0
fi

for unit in "${services[@]}"; do
  unit_properties="$(user_systemctl show "$unit" \
    --property=WorkingDirectory --property=ExecStart --no-pager)" ||
    fail "Failed to inspect effective service properties: $unit"
  working_directory="$(sed -n 's/^WorkingDirectory=//p' <<<"$unit_properties")"
  case "$working_directory" in
    "$deploy_root/current"|"$deploy_root/current/"*) ;;
    *) fail "Service WorkingDirectory does not use the stable current path: $unit" ;;
  esac
  exec_start="$(sed -n 's/^ExecStart=//p' <<<"$unit_properties")"
  if [[ "$exec_start" =~ path=([^[:space:];]+) ]]; then
    exec_path="${BASH_REMATCH[1]}"
  else
    fail "Service ExecStart has no effective executable path: $unit"
  fi
  case "$exec_path" in
    "$deploy_root/current"|"$deploy_root/current/"*) ;;
    *) fail "Service ExecStart does not use the stable current path: $unit" ;;
  esac
done

health_ready() {
  local deadline=$((SECONDS + timeout_seconds))
  local url
  while (( SECONDS <= deadline )); do
    for url in "${health_urls[@]}"; do
      [ "$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)" = 200 ] || {
        sleep 0.2
        continue 2
      }
    done
    return 0
  done
  return 1
}

health_ready || fail 'Pre-switch health checks failed; current was not changed.'

atomic_link() {
  local target="$1"
  temporary_link="$deploy_root/.current.$$.tmp"
  [ ! -e "$temporary_link" ] && [ ! -L "$temporary_link" ] ||
    fail "Temporary link already exists: $temporary_link"
  ln -s "$target" "$temporary_link"
  mv -T "$temporary_link" "$deploy_root/current"
  temporary_link=''
}

cleanup() {
  if [ -n "$temporary_link" ] && [ -L "$temporary_link" ]; then
    unlink "$temporary_link"
  fi
}
trap cleanup EXIT

former_link="$(readlink "$deploy_root/current")"
start_ns="$(date +%s%N)"
atomic_link "releases/$release_id"
if user_systemctl restart "${services[@]}" && health_ready; then
  end_ns="$(date +%s%N)"
  printf 'VERSIONED_RELEASE_SWITCH_OK release=%s ready_ms=%s\n' \
    "$release_id" "$(((end_ns - start_ns) / 1000000))"
  exit 0
fi

printf 'Release verification failed; restoring former current target.\n' >&2
atomic_link "$former_link"
if user_systemctl restart "${services[@]}" && health_ready; then
  printf 'VERSIONED_RELEASE_AUTO_ROLLBACK_OK target=%s\n' "$(readlink -f "$deploy_root/current")" >&2
else
  printf 'Automatic rollback did not restore health; manual recovery is required.\n' >&2
fi
exit 1
