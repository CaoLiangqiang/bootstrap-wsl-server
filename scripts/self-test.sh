#!/usr/bin/env bash
set -Eeuo pipefail

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-wsl-server-test.XXXXXX")"
health_server_pid=''
cleanup() {
  if [ -n "$health_server_pid" ]; then
    kill "$health_server_pid" 2>/dev/null || true
    wait "$health_server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

for script in "$skill_dir"/scripts/*.sh; do bash -n "$script"; done

deploy_fixture="$tmp_dir/versioned-app"
install -d -m 0755 \
  "$deploy_fixture/releases/1.0.0-0123456789ab" \
  "$deploy_fixture/releases/1.1.0-89abcdef0123"
cat > "$deploy_fixture/releases/1.0.0-0123456789ab/.release.json" <<'EOF'
{"release_id":"1.0.0-0123456789ab","git_commit":"0123456789abcdef0123456789abcdef01234567"}
EOF
cat > "$deploy_fixture/releases/1.1.0-89abcdef0123/.release.json" <<'EOF'
{"release_id":"1.1.0-89abcdef0123","git_commit":"89abcdef0123456789abcdef0123456789abcdef"}
EOF
ln -s releases/1.0.0-0123456789ab "$deploy_fixture/current"
bash "$skill_dir/scripts/switch-versioned-release.sh" \
  --deploy-root "$deploy_fixture" \
  --release-id 1.1.0-89abcdef0123 \
  --service demo-api.service \
  --service demo-web.service \
  --health-url http://127.0.0.1:8100/api/health \
  --health-url http://127.0.0.1:5173/ \
  --dry-run | grep -q VERSIONED_RELEASE_DRY_RUN_OK
test "$(readlink "$deploy_fixture/current")" = releases/1.0.0-0123456789ab
fake_systemctl="$tmp_dir/systemctl"
cat > "$fake_systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = --user ] && [ "${2:-}" = show ]; then
  if [ "${SYSTEMCTL_SHOW_MODE:-valid}" = invalid ]; then
    printf 'WorkingDirectory=%s/current-old\nExecStart={ path=%s/currently/bin/service ; }\n' \
      "${DEPLOY_FIXTURE:?}" "${DEPLOY_FIXTURE:?}"
  else
    printf 'WorkingDirectory=%s/current/backend\nExecStart={ path=%s/current/bin/service ; }\n' \
      "${DEPLOY_FIXTURE:?}" "${DEPLOY_FIXTURE:?}"
  fi
  exit 0
fi
if [ "${1:-}" = --user ] && [ "${2:-}" = restart ]; then
  count_file="${SYSTEMCTL_COUNT_FILE:?}"
  count=0
  [ -f "$count_file" ] && count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  [ "$count" -gt 1 ]
  exit
fi
exit 0
EOF
chmod 0755 "$fake_systemctl"
count_file="$tmp_dir/restart-count"
health_port_file="$tmp_dir/health-port"
node -e "const fs=require('fs');const http=require('http');const s=http.createServer((_q,r)=>{r.writeHead(200);r.end('ok')});process.on('SIGTERM',()=>s.close(()=>process.exit(0)));s.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[1],String(s.address().port)))" "$health_port_file" &
health_server_pid=$!
for _ in {1..40}; do
  [ -s "$health_port_file" ] && break
  sleep 0.05
done
test -s "$health_port_file"
health_port="$(cat "$health_port_file")"
if SYSTEMCTL_BIN="$fake_systemctl" SYSTEMCTL_SHOW_MODE=invalid DEPLOY_FIXTURE="$deploy_fixture" \
  bash "$skill_dir/scripts/switch-versioned-release.sh" \
    --deploy-root "$deploy_fixture" \
    --release-id 1.1.0-89abcdef0123 \
    --service demo-api.service \
    --health-url "http://127.0.0.1:$health_port/" >/dev/null 2>&1; then
  printf 'Switch accepted a service that runs from the source checkout.\n' >&2
  exit 1
fi
test "$(readlink "$deploy_fixture/current")" = releases/1.0.0-0123456789ab
if SYSTEMCTL_BIN="$fake_systemctl" SYSTEMCTL_COUNT_FILE="$count_file" DEPLOY_FIXTURE="$deploy_fixture" \
  bash "$skill_dir/scripts/switch-versioned-release.sh" \
    --deploy-root "$deploy_fixture" \
    --release-id 1.1.0-89abcdef0123 \
    --service demo-api.service \
    --health-url "http://127.0.0.1:$health_port/" >/dev/null 2>&1; then
  printf 'Switch unexpectedly succeeded after forced restart failure.\n' >&2
  exit 1
fi
test "$(readlink "$deploy_fixture/current")" = releases/1.0.0-0123456789ab
test "$(cat "$count_file")" = 2
kill "$health_server_pid"
wait "$health_server_pid" 2>/dev/null || true
health_server_pid=''
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
[ "$(stat -c %a "${authorized}.lock")" = 600 ]

ssh-keygen -q -t ed25519 -N '' -C self-test-two -f "$tmp_dir/key-two"
multiple_keys="$tmp_dir/multiple.pub"
{
  cat "$tmp_dir/key.pub"
  cat "$tmp_dir/key-two.pub"
} > "$multiple_keys"
if AUTHORIZED_KEYS_FILE="$authorized" bash "$skill_dir/scripts/add-ssh-public-key.sh" "$multiple_keys" >/dev/null 2>&1; then
  printf 'Multiple public keys were accepted.\n' >&2
  exit 1
fi

limited_authorized="$tmp_dir/limited/authorized_keys"
install -d -m 0700 "$(dirname "$limited_authorized")"
: > "$limited_authorized"
if AUTHORIZED_KEYS_FILE="$limited_authorized" AUTHORIZED_KEYS_MAX_BYTES=10 \
  bash "$skill_dir/scripts/add-ssh-public-key.sh" "$tmp_dir/key.pub" >/dev/null 2>&1; then
  printf 'The authorized-keys size limit was not enforced.\n' >&2
  exit 1
fi
[ ! -s "$limited_authorized" ]

concurrent_authorized="$tmp_dir/concurrent/authorized_keys"
install -d -m 0700 "$(dirname "$concurrent_authorized")"
for _ in 1 2 3 4 5; do
  AUTHORIZED_KEYS_FILE="$concurrent_authorized" \
    bash "$skill_dir/scripts/add-ssh-public-key.sh" "$tmp_dir/key-two.pub" >/dev/null &
done
wait
[ "$(ssh-keygen -lf "$concurrent_authorized" | wc -l)" -eq 1 ]
[ "$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$concurrent_authorized")" -eq 1 ]

rendered="$tmp_dir/rendered-workbench"
bash "$skill_dir/scripts/install-workbench.sh" \
  --windows-user testwindows --windows-hostname testhost --distro TestDistro \
  --ssh-port 2229 --render-only "$rendered" >/dev/null
if rg -n '__[A-Z0-9_]+__' "$rendered"; then
  printf 'Found unresolved workbench template values.\n' >&2
  exit 1
fi
node --check "$rendered/server.js"
node --check "$rendered/public/app.js"
node --check "$rendered/scripts/health-check.js"

registry_fixture="$tmp_dir/registry.json"
cat > "$registry_fixture" <<'EOF'
{
  "schema_version": 1,
  "gateway": {"hostname": "gateway.test-host", "listen": {"host": "127.0.0.1", "port": 8443}},
  "apps": [
    {
      "id": "visible-app",
      "display_name": "Visible App",
      "version": "1.2.3",
      "enabled": true,
      "secrets": ["/private/known-secret-value"],
      "gateway": {
        "hostname": "visible.test-host",
        "windows_listen_port": 443,
        "wsl_listen": "127.0.0.1:8443",
        "tls": "internal-ca",
        "authentication": "basic"
      }
    },
    {
      "id": "internal-only",
      "display_name": "Internal Only",
      "enabled": true,
      "listen": { "host": "127.0.0.1", "port": 8100 }
    },
    {
      "id": "invalid-hostname",
      "display_name": "Invalid Hostname",
      "enabled": true,
      "gateway": {
        "hostname": "https://invalid.example",
        "windows_listen_port": 443,
        "wsl_listen": "127.0.0.1:8443",
        "tls": "internal-ca",
        "authentication": "basic"
      }
    },
    {
      "id": "untrusted-entry",
      "display_name": "Untrusted Entry",
      "enabled": true,
      "gateway": {
        "hostname": "untrusted.test-host",
        "windows_listen_port": "443junk",
        "wsl_listen": "0.0.0.0:8443",
        "tls": "internal-ca",
        "authentication": "none"
      }
    },
    {
      "id": "wrong-gateway-port",
      "display_name": "Wrong Gateway Port",
      "enabled": true,
      "gateway": {
        "hostname": "wrong-port.test-host",
        "windows_listen_port": 443,
        "wsl_listen": "127.0.0.1:8444",
        "tls": "internal-ca",
        "authentication": "basic"
      }
    }
  ]
}
EOF
test_port="$(node -e "const s=require('net').createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")"
WEBUI_REGISTRY_PATH="$registry_fixture" PORT="$test_port" \
  node "$rendered/server.js" >"$tmp_dir/workbench.log" 2>&1 &
workbench_pid=$!
for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:$test_port/api/overview" >"$tmp_dir/overview.json"; then
    break
  fi
  sleep 0.1
done
kill "$workbench_pid" 2>/dev/null || true
wait "$workbench_pid" 2>/dev/null || true
node - "$tmp_dir/overview.json" <<'NODE'
const overview = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (overview.applications.length !== 1) throw new Error('Expected one public WebUI application');
const application = overview.applications[0];
if (application.id !== 'visible-app') throw new Error('Unexpected WebUI application');
if (application.url !== 'https://visible.test-host/') throw new Error('Unexpected WebUI URL');
if (JSON.stringify(overview).includes('internal-only')) throw new Error('Exposed an internal-only application');
if (JSON.stringify(overview).includes('invalid-hostname')) throw new Error('Exposed an invalid gateway hostname');
if (JSON.stringify(overview).includes('untrusted-entry')) throw new Error('Exposed an untrusted gateway entry');
if (JSON.stringify(overview).includes('wrong-gateway-port')) throw new Error('Exposed a mismatched gateway entry');
if (JSON.stringify(overview).includes('known-secret-value')) throw new Error('Exposed a registry secret path');
NODE

manuals="$tmp_dir/manuals"
bash "$skill_dir/scripts/render-manuals.sh" \
  --wsl-user testuser --windows-user testwindows --windows-hostname testhost \
  --distro TestDistro --ssh-port 2229 --output-dir "$manuals" >/dev/null
host_manual="$manuals/wsl-server-host-manual.html"
client_manual="$manuals/wsl-server-client-manual.html"
migration_manual="$manuals/wsl-server-project-migration-manual.html"
test -s "$host_manual"
test -s "$client_manual"
test -s "$migration_manual"
grep -q '主机端管理员手册' "$host_manual"
grep -q '客户端访问手册' "$client_manual"
grep -q '项目移植' "$migration_manual"
grep -q 'testhost' "$client_manual"
grep -q '2229' "$host_manual"
grep -q 'testhost' "$migration_manual"
grep -q '2229' "$migration_manual"
if rg -n '__[A-Z0-9_]+__' "$host_manual" "$client_manual" "$migration_manual"; then
  printf 'Found unresolved manual template values.\n' >&2
  exit 1
fi

if rg -n 'caojiang|cjnotebook1|10\.197|Manage-WslSshPort' \
  "$skill_dir/SKILL.md" "$skill_dir/references" "$skill_dir/assets" "$skill_dir/agents" \
  --glob '!assets/workbench/public/vendor/lucide.min.js'; then
  printf 'Found machine-specific or obsolete content.\n' >&2
  exit 1
fi

printf 'SELF_TEST_OK\n'
