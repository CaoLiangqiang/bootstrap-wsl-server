#!/usr/bin/env bash
set -Eeuo pipefail

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
  --install-dir /srv/wsl-server/apps \
  --render-only "$rendered"

test -x "$rendered/scripts/check-app-health.py"
test "$(stat -c %a "$rendered/registry.json")" = 644
if rg -n '__[A-Z0-9_]+__|caojiang|cjnotebook1|known-secret-value' "$rendered"; then
  printf 'Rendered output contains a placeholder, host-specific value, or secret.\n' >&2
  exit 1
fi
python3 "$rendered/scripts/check-app-health.py" \
  --registry "$rendered/registry.json" --validate

if bash "$skill_dir/scripts/install-webui-apps.sh" \
  --app-id invalid_app \
  --app-name Invalid \
  --service-unit invalid.service \
  --app-port 8102 \
  --health-path /health \
  --gateway-hostname demo-host \
  --gateway-port 8443 \
  --caddy-bin /nonexistent/caddy \
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
