#!/usr/bin/env bash
set -Eeuo pipefail

command -v grep >/dev/null 2>&1 || { printf 'Required command is missing: grep\n' >&2; exit 127; }

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/webui-skill-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

rendered="$tmp_dir/rendered"
bash "$skill_dir/scripts/install-webui-apps.sh" \
  --app-id demo-app \
  --app-name 'Demo WebUI' \
  --service-unit demo-app.service \
  --app-port 8101 \
  --health-path /api/health \
  --gateway-hostname demo-host \
  --gateway-port 8443 \
  --caddy-bin /nonexistent/caddy \
  --source-path /srv/source/demo-app \
  --deploy-root /srv/apps/demo-app \
  --release-id 1.2.3-0123456789ab \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --app-version 1.2.3 \
  --install-dir /srv/wsl-server/apps \
  --render-only "$rendered"

test -x "$rendered/scripts/check-app-health.py"
test "$(stat -c %a "$rendered/registry.json")" = 644
if grep -ERn '__[A-Z0-9_]+__|caojiang|cjnotebook1|known-secret-value' "$rendered"; then
  printf 'Rendered output contains a placeholder, host-specific value, or secret.\n' >&2
  exit 1
fi
python3 "$rendered/scripts/check-app-health.py" \
  --registry "$rendered/registry.json" --validate
legacy_registry="$tmp_dir/legacy-registry.json"
cat > "$legacy_registry" <<'EOF'
{
  "schema_version": 1,
  "apps": [
    {
      "id": "legacy-app",
      "display_name": "Legacy App",
      "enabled": true,
      "service_unit": "legacy-app.service",
      "listen": {"host": "127.0.0.1", "port": 8102},
      "health": {
        "url": "http://127.0.0.1:8102/health",
        "expected_status": [200],
        "timeout_seconds": 2
      }
    }
  ]
}
EOF
python3 "$rendered/scripts/check-app-health.py" --registry "$legacy_registry" --validate
python3 - "$legacy_registry" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
registry = json.loads(path.read_text(encoding="utf-8"))
registry["apps"][0]["health"]["url"] = "http://0.0.0.0:8102/health"
path.write_text(json.dumps(registry), encoding="utf-8")
PY
if python3 "$rendered/scripts/check-app-health.py" --registry "$legacy_registry" --validate >/dev/null 2>&1; then
  printf 'Validator accepted a non-loopback legacy health URL.\n' >&2
  exit 1
fi
python3 - "$rendered/registry.json" <<'PY'
import json
import pathlib
import sys

registry = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert registry["sync_projects"] == []
gateway = registry["apps"][0]["gateway"]
app = registry["apps"][0]
assert gateway["hostname"] == "demo-host"
assert gateway["windows_listen_port"] == 443
assert gateway["wsl_listen"] == "127.0.0.1:8443"
assert gateway["tls"] == "internal-ca"
assert gateway["authentication"] == "basic"
assert app["source_path"] == "/srv/source/demo-app"
assert app["version"] == "1.2.3"
assert app["git_commit"] == "0123456789abcdef0123456789abcdef01234567"
assert app["deployment"] == {
    "strategy": "versioned-current-symlink",
    "deploy_root": "/srv/apps/demo-app",
    "current_path": "/srv/apps/demo-app/current",
    "current_release": "1.2.3-0123456789ab",
    "release_path": "/srv/apps/demo-app/releases/1.2.3-0123456789ab",
    "source_commit": "0123456789abcdef0123456789abcdef01234567",
}
app["deployment"]["previous_release"] = "1.2.2-fedcba987654"
app["deployment"]["previous_release_path"] = "/srv/apps/demo-app/releases/1.2.2-fedcba987654"
registry["sync_projects"] = [
    {
        "id": "demo-app", "enabled": True, "source_path": "/srv/source/demo-app",
        "source_origin": "git@example.invalid:group/demo-app.git", "remote": "origin",
        "deploy_root": "/srv/apps/demo-app", "sync_policy": "fetch-only",
        "timeout_seconds": 60, "retries": 2,
    },
    {
        "id": "staged-app", "enabled": True, "source_path": "/srv/source/staged-app",
        "source_origin": "ssh://git@example.invalid/group/staged-app.git", "remote": "origin",
        "deploy_root": "/srv/apps/staged-app", "sync_policy": "stage-release",
        "timeout_seconds": 90, "retries": 1,
        "stage_release": {
            "kind": "tag", "value": "v1.2.3",
            "expected_commit": "0123456789abcdef0123456789abcdef01234567",
            "release_id": "1.2.3-0123456789ab",
            "verify_hook": ".wsl-server/stage-release", "verify_args": ["--offline"],
        },
    },
]
pathlib.Path(sys.argv[1]).write_text(json.dumps(registry), encoding="utf-8")
PY
python3 "$rendered/scripts/check-app-health.py" \
  --registry "$rendered/registry.json" --validate

sync_only_registry="$tmp_dir/sync-only-registry.json"
cat > "$sync_only_registry" <<'EOF'
{
  "schema_version": 1,
  "sync_projects": [
    {
      "id": "source-only", "enabled": true,
      "source_path": "/srv/source/source-only",
      "source_origin": "git@example.invalid:group/source-only.git",
      "remote": "origin", "deploy_root": "/srv/apps/source-only",
      "sync_policy": "fetch-only", "timeout_seconds": 60, "retries": 1
    }
  ],
  "apps": []
}
EOF
python3 "$rendered/scripts/check-app-health.py" \
  --registry "$sync_only_registry" --validate

python3 - "$rendered/scripts/check-app-health.py" <<'PY'
import copy
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("registry_validator", pathlib.Path(sys.argv[1]))
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
base = {
    "id": "demo-app", "enabled": True, "source_path": "/srv/source/demo-app",
    "source_origin": "https://example.invalid/group/demo-app.git", "remote": "origin",
    "deploy_root": "/srv/apps/demo-app", "sync_policy": "fetch-only",
    "timeout_seconds": 60, "retries": 1,
}
invalid = []
case = copy.deepcopy(base); case["source_origin"] = "https://user:secret@example.invalid/repo.git"; invalid.append(case)
case = copy.deepcopy(base); case["source_path"] = "/srv/%n/source"; invalid.append(case)
case = copy.deepcopy(base); case["remote"] = "upstream"; invalid.append(case)
case = copy.deepcopy(base); case["sync_policy"] = "stage-release"; invalid.append(case)
case = copy.deepcopy(base); case["stage_release"] = {}; invalid.append(case)
for tag in ("bad..tag", ".hidden", "trailing.", "folder/.hidden", "name.lock"):
    case = copy.deepcopy(base)
    case["sync_policy"] = "stage-release"
    case["stage_release"] = {
        "kind": "tag", "value": tag,
        "expected_commit": "0123456789abcdef0123456789abcdef01234567",
        "release_id": "candidate", "verify_hook": "verify", "verify_args": [],
    }
    invalid.append(case)
for case in invalid:
    try:
        module.validate_sync_projects([case])
    except module.RegistryError:
        continue
    raise AssertionError(f"validator accepted invalid sync project: {case!r}")
PY

if bash "$skill_dir/scripts/install-webui-apps.sh" \
  --app-id invalid_app \
  --app-name Invalid \
  --service-unit invalid.service \
  --app-port 8102 \
  --health-path /health \
  --gateway-hostname demo-host \
  --gateway-port 8443 \
  --caddy-bin /nonexistent/caddy \
  --source-path /srv/source/invalid \
  --deploy-root /srv/apps/invalid \
  --release-id 1.0.0-0123456789ab \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --app-version 1.0.0 \
  --install-dir /srv/wsl-server/apps \
  --render-only "$tmp_dir/invalid" >/dev/null 2>&1; then
  printf 'Installer accepted an invalid application id.\n' >&2
  exit 1
fi

if bash "$skill_dir/scripts/install-webui-apps.sh" \
  --app-id demo-app \
  --app-name 'Demo WebUI' \
  --service-unit demo-app.service \
  --app-port 8101 \
  --health-path /api/health \
  --gateway-hostname demo-host \
  --gateway-port 8443 \
  --caddy-bin /bin/true \
  --source-path /srv/source/demo-app \
  --deploy-root /srv/apps/demo-app \
  --release-id 1.2.3-0123456789ab \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --app-version 1.2.3 \
  --install-dir "$tmp_dir/invalid-caddy" >/dev/null 2>&1; then
  printf 'Installer accepted an executable that is not Caddy.\n' >&2
  exit 1
fi
test ! -e "$tmp_dir/invalid-caddy"

python3 - "$rendered/scripts/check-app-health.py" <<'PY'
import importlib.util
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

checker_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("webui_health", checker_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
module.service_state = lambda _unit: "active"

target_requests = 0

class TargetHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        global target_requests
        target_requests += 1
        self.send_response(200)
        self.end_headers()

    def log_message(self, _format, *_args):
        pass

target = ThreadingHTTPServer(("127.0.0.1", 0), TargetHandler)

class SourceHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect-local":
            self.send_response(302)
            self.send_header("Location", "/health")
            self.end_headers()
        elif self.path == "/redirect-cross":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{target.server_port}/health")
            self.end_headers()
        else:
            self.send_response(200)
            self.end_headers()

    def log_message(self, _format, *_args):
        pass

source = ThreadingHTTPServer(("127.0.0.1", 0), SourceHandler)
threads = [
    threading.Thread(target=server.serve_forever, daemon=True)
    for server in (source, target)
]
for thread in threads:
    thread.start()

def app(path):
    return {
        "id": "demo-app",
        "service_unit": "demo-app.service",
        "listen": {"host": "127.0.0.1", "port": source.server_port},
        "health": {
            "path": path,
            "expected_status": [200],
            "timeout_seconds": 2,
            "max_same_origin_redirects": 3,
        },
    }

try:
    same_origin = module.check_app(app("/redirect-local"))
    assert same_origin["healthy"], same_origin
    legacy = app("/health")
    legacy["health"] = {
        "url": f"http://127.0.0.1:{source.server_port}/health",
        "expected_status": [200],
        "timeout_seconds": 2,
    }
    legacy_result = module.check_app(legacy)
    assert legacy_result["healthy"], legacy_result
    cross_origin = module.check_app(app("/redirect-cross"))
    assert not cross_origin["healthy"], cross_origin
    assert "cross-origin" in (cross_origin["error"] or ""), cross_origin
    assert target_requests == 0, target_requests
finally:
    source.shutdown()
    target.shutdown()
    source.server_close()
    target.server_close()
PY

test_caddy="${CADDY_BIN:-$(command -v caddy || true)}"
if [ -n "$test_caddy" ] && [ -x "$test_caddy" ]; then
  GATEWAY_USERNAME=test \
  GATEWAY_PASSWORD_HASH='$2a$14$00000000000000000000000000000000000000000000000000000' \
    "$test_caddy" adapt \
      --config "$rendered/gateway/Caddyfile" --adapter caddyfile >/dev/null
fi

printf 'WEBUI_SKILL_SELF_TEST_OK\n'
