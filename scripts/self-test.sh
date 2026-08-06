#!/usr/bin/env bash
set -Eeuo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-wsl-server-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

for script in "$skill_dir"/scripts/*.sh; do bash -n "$script"; done
for script in \
  "$skill_dir/assets/workbench/server.js" \
  "$skill_dir/assets/workbench/public/app.js" \
  "$skill_dir/assets/workbench/scripts/health-check.js"; do
  node --check "$script"
done
node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" \
  "$skill_dir/assets/workbench/package.json"

fixture="$tmp_dir/wsl.conf"
cat > "$fixture" <<'EOF'
[boot]
systemd=false

[network]
generateResolvConf=true

[interop]
appendWindowsPath=true
EOF
bash "$skill_dir/scripts/configure-wsl-base.sh" \
  --file "$fixture" --user testuser --isolate-windows-path >/dev/null
grep -qx 'systemd=true' "$fixture"
grep -qx 'default=testuser' "$fixture"
grep -qx 'appendWindowsPath=false' "$fixture"
grep -qx 'generateResolvConf=true' "$fixture"
bash "$skill_dir/scripts/configure-wsl-base.sh" \
  --file "$fixture" --user testuser --isolate-windows-path >/dev/null

bash "$skill_dir/scripts/configure-wsl-sshd.sh" \
  --user testuser --password-auth yes --dry-run > "$tmp_dir/sshd.conf"
grep -qx 'PermitRootLogin no' "$tmp_dir/sshd.conf"
grep -qx 'PubkeyAuthentication yes' "$tmp_dir/sshd.conf"
grep -qx 'PasswordAuthentication yes' "$tmp_dir/sshd.conf"
grep -qx 'AllowUsers testuser' "$tmp_dir/sshd.conf"

ssh-keygen -q -t ed25519 -N '' -C self-test -f "$tmp_dir/key"
authorized="$tmp_dir/ssh/authorized_keys"
install -d -m 0700 "$(dirname "$authorized")"
printf '# existing file without final newline' > "$authorized"
AUTHORIZED_KEYS_FILE="$authorized" bash "$skill_dir/scripts/add-ssh-public-key.sh" "$tmp_dir/key.pub" >/dev/null
AUTHORIZED_KEYS_FILE="$authorized" bash "$skill_dir/scripts/add-ssh-public-key.sh" "$tmp_dir/key.pub" >/dev/null
[ "$(ssh-keygen -lf "$authorized" | wc -l)" -eq 1 ]
[ "$(stat -c %a "$(dirname "$authorized")")" = 700 ]
[ "$(stat -c %a "$authorized")" = 600 ]

rendered="$tmp_dir/rendered-workbench"
bash "$skill_dir/scripts/install-workbench.sh" \
  --windows-user testwindows --windows-hostname testhost --distro TestDistro \
  --ssh-port 2229 --render-only "$rendered" >/dev/null
if rg -n '__WSL_USER__|__WINDOWS_USER__|__WINDOWS_HOSTNAME__|__DISTRO__|__SSH_PORT__' "$rendered"; then
  printf 'Found unresolved workbench template values.\n' >&2
  exit 1
fi
node --check "$rendered/server.js"
node --check "$rendered/public/app.js"
node --check "$rendered/scripts/health-check.js"

if rg -n 'caojiang|cjnotebook1|10\.197|Manage-WslSshPort|node_modules' \
  "$skill_dir/SKILL.md" "$skill_dir/references" "$skill_dir/assets" "$skill_dir/agents" \
  --glob '!assets/workbench/public/vendor/lucide.min.js'; then
  printf 'Found machine-specific or obsolete content.\n' >&2
  exit 1
fi

printf 'SELF_TEST_OK\n'
