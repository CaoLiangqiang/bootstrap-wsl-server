#!/usr/bin/env bash
set -Eeuo pipefail

command -v grep >/dev/null 2>&1 || { printf 'Required command is missing: grep\n' >&2; exit 127; }
command -v find >/dev/null 2>&1 || { printf 'Required command is missing: find\n' >&2; exit 127; }

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/no-ripgrep-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
marker="$tmp_dir/unexpected-ripgrep-call"
install -d -m 0755 "$fake_bin" "$tmp_dir/config"
cat > "$fake_bin/rg" <<EOF
#!/usr/bin/env sh
: > "$marker"
printf 'ripgrep must not be required by repository scripts.\n' >&2
exit 127
EOF
chmod 0755 "$fake_bin/rg"

if find "$skill_dir/scripts" -type f ! -name 'self-test-no-ripgrep.sh' \
  -exec grep -En '(^|[^[:alnum:]_])rg([^[:alnum:]_]|$)' {} +; then
  printf 'A repository script still references ripgrep.\n' >&2
  exit 1
fi

PATH="$fake_bin:$PATH" bash "$skill_dir/scripts/render-manuals.sh" \
  --wsl-user testuser --windows-user testwindows --windows-hostname testhost \
  --distro TestDistro --ssh-port 2229 --output-dir "$tmp_dir/manuals" >/dev/null

printf '{"schema_version":1,"sync_projects":[],"apps":[]}\n' > "$tmp_dir/config/registry.json"
PATH="$fake_bin:$PATH" HOME="$tmp_dir/home" \
  bash "$skill_dir/scripts/install-project-sync.sh" \
    --registry "$tmp_dir/config/registry.json" \
    --install-dir "$tmp_dir/project-sync" \
    --state-dir "$tmp_dir/state" \
    --render-only "$tmp_dir/project-sync" >/dev/null

test ! -e "$marker"

if PATH="$fake_bin" /usr/bin/bash "$skill_dir/scripts/render-manuals.sh" \
  >"$tmp_dir/missing-grep.log" 2>&1; then
  printf 'Renderer silently accepted a missing required command.\n' >&2
  exit 1
fi
grep -q 'Required command is missing: grep' "$tmp_dir/missing-grep.log"

printf 'NO_RIPGREP_SELF_TEST_OK\n'
