#!/usr/bin/env bash
set -Eeuo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wsl-project-sync-test.XXXXXX")"
lock_pid=''
cleanup() {
  if [ -n "$lock_pid" ]; then kill "$lock_pid" 2>/dev/null || true; fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

remote="$tmp_dir/remote.git"
publisher="$tmp_dir/publisher"
source="$tmp_dir/source"
deploy="$tmp_dir/deploy"
state="$tmp_dir/state"
registry="$tmp_dir/registry.json"
git init --bare --initial-branch=main "$remote" >/dev/null
git init -b main "$publisher" >/dev/null
git -C "$publisher" config user.name fixture
git -C "$publisher" config user.email fixture@example.invalid
install -d -m 0755 "$publisher/.wsl-server"
cat > "$publisher/.wsl-server/stage-release" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
test -f payload.txt
test "${1:-}" = fixture-check
EOF
chmod 0755 "$publisher/.wsl-server/stage-release"
printf 'one\n' > "$publisher/payload.txt"
git -C "$publisher" add .
git -C "$publisher" commit -m initial >/dev/null
git -C "$publisher" remote add origin "file://$remote"
git -C "$publisher" push -u origin main >/dev/null
git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
git clone "file://$remote" "$source" >/dev/null
install -d -m 0755 "$deploy/releases"
ln -s releases/never-changed "$deploy/current"

write_registry() {
  local policy="$1" selector_json="${2:-}"
  cat > "$registry" <<EOF
{
  "schema_version": 1,
  "apps": [],
  "sync_projects": [
    {
      "id": "fixture-project",
      "enabled": true,
      "source_path": "$source",
      "source_origin": "file://$remote",
      "remote": "origin",
      "deploy_root": "$deploy",
      "sync_policy": "$policy",
      "timeout_seconds": 10,
      "retries": 1${selector_json}
    }
  ]
}
EOF
}

sync_script="$skill_dir/assets/project-sync/sync-projects.py"
write_registry fetch-only
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" --validate
duplicate_registry="$tmp_dir/duplicate-registry.json"
printf '{"schema_version":1,"apps":[],"sync_projects":[],"sync_projects":[]}\n' > "$duplicate_registry"
if python3 "$sync_script" --registry "$duplicate_registry" \
  --state-dir "$state" --validate >/dev/null 2>&1; then
  printf 'Duplicate JSON keys were accepted.\n' >&2
  exit 1
fi
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" --dry-run | grep -q SYNC_DRY_RUN_OK
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" | grep -q SYNC_OK

printf 'dirty\n' > "$source/local-only.txt"
printf 'two\n' >> "$publisher/payload.txt"
git -C "$publisher" add payload.txt
git -C "$publisher" commit -m update >/dev/null
approved_commit="$(git -C "$publisher" rev-parse HEAD)"
git -C "$publisher" tag v1.0.0
git -C "$publisher" push origin main v1.0.0 >/dev/null
current_before="$(readlink "$deploy/current")"
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" | grep -q SYNC_OK
python3 - "$state/fixture-project.json" "$approved_commit" <<'PY'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report["status"] == "ok"
assert report["remote_head"] == sys.argv[2]
assert report["has_update"] is True
assert report["behind"] == 1
assert report["worktree_dirty"] is True
PY
test -f "$source/local-only.txt"
test "$(git -C "$source" rev-parse HEAD)" != "$approved_commit"
test "$(readlink "$deploy/current")" = "$current_before"

# Fetch prunes deleted remote branches without touching the worktree.
git -C "$publisher" branch old-branch
git -C "$publisher" push origin old-branch >/dev/null
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >/dev/null
git -C "$source" show-ref --verify --quiet refs/remotes/origin/old-branch
git -C "$publisher" push origin --delete old-branch >/dev/null
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >/dev/null
if git -C "$source" show-ref --verify --quiet refs/remotes/origin/old-branch; then
  printf 'Fetch did not prune a deleted remote branch.\n' >&2
  exit 1
fi

selector=",
      \"stage_release\": {
        \"kind\": \"tag\",
        \"value\": \"v1.0.0\",
        \"expected_commit\": \"$approved_commit\",
        \"release_id\": \"1.0.0-${approved_commit:0:12}\",
        \"verify_hook\": \".wsl-server/stage-release\",
        \"verify_args\": [\"fixture-check\"]
      }"
write_registry stage-release "$selector"
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" | grep -q SYNC_OK
release="$deploy/releases/1.0.0-${approved_commit:0:12}"
test -f "$release/payload.txt"
test ! -e "$release/.git"
python3 - "$release/.release.json" "$approved_commit" <<'PY'
import json, pathlib, sys
metadata = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert metadata["git_commit"] == sys.argv[2]
PY
test "$(readlink "$deploy/current")" = "$current_before"
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" | grep -q SYNC_OK

# Archive links are rejected so extraction cannot traverse through a link.
ln -s payload.txt "$publisher/payload-link"
git -C "$publisher" add payload-link
git -C "$publisher" commit -m symlink-fixture >/dev/null
link_commit="$(git -C "$publisher" rev-parse HEAD)"
git -C "$publisher" tag v1.1.0
git -C "$publisher" push origin main v1.1.0 >/dev/null
link_selector=",
      \"stage_release\": {
        \"kind\": \"tag\",
        \"value\": \"v1.1.0\",
        \"expected_commit\": \"$link_commit\",
        \"release_id\": \"1.1.0-${link_commit:0:12}\",
        \"verify_hook\": \".wsl-server/stage-release\",
        \"verify_args\": [\"fixture-check\"]
      }"
write_registry stage-release "$link_selector"
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >/dev/null 2>&1; then
  printf 'Archive symlink was accepted.\n' >&2
  exit 1
fi
grep -q 'unsupported entry type' "$state/fixture-project.json"
test ! -e "$deploy/releases/1.1.0-${link_commit:0:12}"
test "$(readlink "$deploy/current")" = "$current_before"

# A conflicting release is rejected and current remains unchanged.
write_registry stage-release "$selector"
python3 - "$release/.release.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
metadata = json.loads(path.read_text())
metadata["git_commit"] = "0" * 40
path.write_text(json.dumps(metadata))
PY
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >/dev/null 2>&1; then
  printf 'Conflicting release metadata was accepted.\n' >&2
  exit 1
fi
grep -q 'release destination conflicts' "$state/fixture-project.json"
test "$(readlink "$deploy/current")" = "$current_before"
python3 - "$release/.release.json" "$approved_commit" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
metadata = json.loads(path.read_text())
metadata["git_commit"] = sys.argv[2]
path.write_text(json.dumps(metadata))
PY

# Origin mismatch and embedded HTTPS credentials fail without leaking the URL.
write_registry fetch-only
python3 - "$registry" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text())
registry["sync_projects"][0]["source_origin"] = "file:///not-the-configured-origin"
path.write_text(json.dumps(registry))
PY
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >"$tmp_dir/mismatch.log" 2>&1; then
  printf 'Origin mismatch was accepted.\n' >&2
  exit 1
fi
grep -q 'configured origin does not exactly match' "$state/fixture-project.json"
if rg -n 'not-the-configured-origin|file://' "$tmp_dir/mismatch.log"; then
  printf 'Origin was exposed in sync logs.\n' >&2
  exit 1
fi
python3 - "$registry" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text())
registry["sync_projects"][0]["source_origin"] = "https://user:secret@example.invalid/repo.git"
path.write_text(json.dumps(registry))
PY
if python3 "$sync_script" --registry "$registry" --state-dir "$state" --validate \
  >"$tmp_dir/credential.log" 2>&1; then
  printf 'Credential-bearing HTTPS origin was accepted.\n' >&2
  exit 1
fi
if rg -n 'user:secret' "$tmp_dir/credential.log"; then
  printf 'Credential-bearing origin was exposed in validation logs.\n' >&2
  exit 1
fi

write_registry fetch-only
python3 - "$registry" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text())
registry["sync_projects"][0]["source_path"] = "/srv/%n/source"
path.write_text(json.dumps(registry))
PY
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" --validate >/dev/null 2>&1; then
  printf 'A systemd-unsafe project path was accepted.\n' >&2
  exit 1
fi

# Fetch failure keeps locally observable state and records only a safe category.
write_registry fetch-only
git -C "$source" remote set-url origin "file://$tmp_dir/missing.git"
python3 - "$registry" "$tmp_dir/missing.git" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text())
registry["sync_projects"][0]["source_origin"] = f"file://{sys.argv[2]}"
path.write_text(json.dumps(registry))
PY
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >"$tmp_dir/fetch-failure.log" 2>&1; then
  printf 'Missing remote fetch unexpectedly succeeded.\n' >&2
  exit 1
fi
python3 - "$state/fixture-project.json" "$(git -C "$source" rev-parse HEAD)" <<'PY'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report["status"] == "failed"
assert report["observed_head"] == sys.argv[2]
assert report["observed_head_before_fetch"] == sys.argv[2]
assert report["remote_head"] is None
assert report["failure"] in {"git-failed", "not-found"}
PY
if rg -n 'missing\.git|file://' "$tmp_dir/fetch-failure.log"; then
  printf 'Failed origin was exposed in sync logs.\n' >&2
  exit 1
fi
git -C "$source" remote set-url origin "file://$remote"

# Invalid Git tag syntax and a failing hook are rejected; failed stages are cleaned.
write_registry stage-release "$selector"
python3 - "$registry" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text())
registry["sync_projects"][0]["stage_release"]["value"] = "bad..tag"
path.write_text(json.dumps(registry))
PY
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" --validate >/dev/null 2>&1; then
  printf 'Invalid Git tag syntax was accepted.\n' >&2
  exit 1
fi
rm -rf "$release"
write_registry stage-release "$selector"
python3 - "$registry" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text())
registry["sync_projects"][0]["stage_release"]["verify_args"] = ["fail"]
path.write_text(json.dumps(registry))
PY
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >/dev/null 2>&1; then
  printf 'Failing release hook was accepted.\n' >&2
  exit 1
fi
test ! -e "$release"
if find "$deploy/releases" -maxdepth 1 -name '.stage-*' -print -quit | grep -q .; then
  printf 'Failed staging left a temporary directory.\n' >&2
  exit 1
fi

write_registry auto-deploy
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" >/dev/null 2>&1; then
  printf 'auto-deploy was not rejected.\n' >&2
  exit 1
fi
grep -q 'auto-deploy is disabled' "$state/fixture-project.json"

write_registry fetch-only
flock "$state/.sync.lock" sleep 5 &
lock_pid=$!
sleep 0.1
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 python3 "$sync_script" \
  --registry "$registry" --state-dir "$state" | grep -q SYNC_ALREADY_RUNNING
kill "$lock_pid"
wait "$lock_pid" 2>/dev/null || true
lock_pid=''

rendered="$tmp_dir/rendered"
WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 HOME="$tmp_dir/home" \
  bash "$skill_dir/scripts/install-project-sync.sh" \
    --registry "$registry" --install-dir /srv/wsl-project-sync \
    --state-dir "$tmp_dir/rendered-state" --render-only "$rendered" >/dev/null
test -x "$rendered/sync-projects.py"
grep -Fq -- "-$source/.git" "$rendered/wsl-project-sync.service"
if rg -n '__[A-Z0-9_]+__|caojiang|cjnotebook1|known-secret-value' "$rendered"; then
  printf 'Rendered project sync output contains unsafe content.\n' >&2
  exit 1
fi

# A unit conflict is detected before the install destination or any link is made.
conflict_home="$tmp_dir/conflict-home"
install -d "$conflict_home/.config/systemd/user"
touch "$conflict_home/.config/systemd/user/wsl-project-sync.timer"
if WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN=1 HOME="$conflict_home" \
  bash "$skill_dir/scripts/install-project-sync.sh" \
    --registry "$registry" --install-dir "$tmp_dir/conflict-install" \
    --state-dir "$tmp_dir/conflict-state" >/dev/null 2>&1; then
  printf 'Installer accepted an existing unit conflict.\n' >&2
  exit 1
fi
test ! -e "$tmp_dir/conflict-install"
test ! -e "$conflict_home/.config/systemd/user/wsl-project-sync.service"

printf 'PROJECT_SYNC_SELF_TEST_OK\n'
