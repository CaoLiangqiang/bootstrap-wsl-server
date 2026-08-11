#!/usr/bin/env python3
"""Strict, read-only health checks for registered loopback WebUI apps."""

from __future__ import annotations

import argparse
import ipaddress
import json
import math
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_REGISTRY = Path(__file__).resolve().parent.parent / "registry.json"
MAX_REGISTRY_BYTES = 1024 * 1024
APP_ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
UNIT_RE = re.compile(r"^[A-Za-z0-9_.:@-]+\.service$")
HOST_RE = re.compile(
    r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*\Z"
)
REDIRECT_CODES = {301, 302, 303, 307, 308}


class RegistryError(ValueError):
    pass


class CrossOriginRedirectError(urllib.error.URLError):
    pass


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RegistryError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def require_keys(value: Any, expected: set[str], context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RegistryError(f"{context} must be an object")
    actual = set(value)
    if actual != expected:
        extra = sorted(actual - expected)
        missing = sorted(expected - actual)
        raise RegistryError(f"{context} keys differ: missing={missing} unknown={extra}")
    return value


def valid_text(value: Any, context: str, maximum: int) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= maximum:
        raise RegistryError(f"{context} must be a string of 1 to {maximum} characters")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise RegistryError(f"{context} contains a control character")
    return value


def valid_port(value: Any, context: str) -> int:
    if type(value) is not int or not 1024 <= value <= 65535:
        raise RegistryError(f"{context} must be an integer from 1024 to 65535")
    return value


def valid_hostname(value: Any) -> str:
    hostname = valid_text(value, "gateway.hostname", 253)
    if hostname != hostname.lower() or not HOST_RE.fullmatch(hostname):
        raise RegistryError("gateway.hostname must be a lowercase ASCII DNS hostname")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        raise RegistryError("gateway.hostname must not be an IP address")
    if hostname == "localhost":
        raise RegistryError("gateway.hostname must not be localhost")
    return hostname


def valid_health_path(value: Any) -> str:
    path = valid_text(value, "health.path", 512)
    if not path.startswith("/") or path.startswith("//") or "\\" in path or any(char.isspace() for char in path):
        raise RegistryError("health.path must be a single absolute URL path")
    parsed = urllib.parse.urlsplit(path)
    if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or parsed.path != path:
        raise RegistryError("health.path must not contain an origin, query, or fragment")
    decoded = urllib.parse.unquote(path)
    if any(ord(char) < 32 or ord(char) == 127 for char in decoded):
        raise RegistryError("health.path decodes to a control character")
    if any(segment in {".", ".."} for segment in decoded.split("/")):
        raise RegistryError("health.path must not contain dot segments")
    return path


def load_registry(path: Path) -> list[dict[str, Any]]:
    try:
        if path.stat().st_size > MAX_REGISTRY_BYTES:
            raise RegistryError("registry is larger than 1 MiB")
        document = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    except RegistryError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot read registry {path}: {exc}") from exc

    root = require_keys(document, {"schema_version", "gateway", "apps"}, "registry")
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        raise RegistryError("schema_version must be integer 1")

    gateway = require_keys(root["gateway"], {"hostname", "listen"}, "gateway")
    valid_hostname(gateway["hostname"])
    gateway_listen = require_keys(gateway["listen"], {"host", "port"}, "gateway.listen")
    if gateway_listen["host"] != "127.0.0.1":
        raise RegistryError("gateway.listen.host must be 127.0.0.1")
    gateway_port = valid_port(gateway_listen["port"], "gateway.listen.port")

    if not isinstance(root["apps"], list) or not root["apps"]:
        raise RegistryError("apps must be a non-empty array")
    ids: set[str] = set()
    ports = {gateway_port}
    apps: list[dict[str, Any]] = []
    for index, raw_app in enumerate(root["apps"]):
        context = f"apps[{index}]"
        app = require_keys(
            raw_app,
            {"id", "display_name", "enabled", "service_unit", "listen", "health"},
            context,
        )
        app_id = valid_text(app["id"], f"{context}.id", 32)
        if not APP_ID_RE.fullmatch(app_id) or app_id in {"gateway", "workbench"}:
            raise RegistryError(f"{context}.id is invalid or reserved")
        if app_id in ids:
            raise RegistryError(f"duplicate app id: {app_id}")
        ids.add(app_id)
        valid_text(app["display_name"], f"{context}.display_name", 80)
        if type(app["enabled"]) is not bool:
            raise RegistryError(f"{context}.enabled must be boolean")
        unit = valid_text(app["service_unit"], f"{context}.service_unit", 128)
        if not UNIT_RE.fullmatch(unit):
            raise RegistryError(f"{context}.service_unit must be a service unit basename")

        listen = require_keys(app["listen"], {"host", "port"}, f"{context}.listen")
        if listen["host"] != "127.0.0.1":
            raise RegistryError(f"{context}.listen.host must be 127.0.0.1")
        port = valid_port(listen["port"], f"{context}.listen.port")
        if port in ports or port == 4173:
            raise RegistryError(f"{context}.listen.port conflicts with a reserved or registered port")
        ports.add(port)

        health = require_keys(
            app["health"],
            {"path", "expected_status", "timeout_seconds", "max_same_origin_redirects"},
            f"{context}.health",
        )
        valid_health_path(health["path"])
        statuses = health["expected_status"]
        if (
            not isinstance(statuses, list)
            or not 1 <= len(statuses) <= 8
            or any(type(status) is not int or not 100 <= status <= 599 for status in statuses)
            or len(set(statuses)) != len(statuses)
        ):
            raise RegistryError(f"{context}.health.expected_status is invalid")
        timeout = health["timeout_seconds"]
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or not 0.1 <= timeout <= 30:
            raise RegistryError(f"{context}.health.timeout_seconds must be from 0.1 to 30")
        redirects = health["max_same_origin_redirects"]
        if type(redirects) is not int or not 0 <= redirects <= 5:
            raise RegistryError(f"{context}.health.max_same_origin_redirects must be from 0 to 5")
        apps.append(app)
    return apps


def service_state(unit: str) -> str:
    try:
        result = subprocess.run(
            ["systemctl", "--user", "show", unit, "--property=ActiveState", "--value"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"error:{exc}"
    state = result.stdout.strip()
    return state if result.returncode == 0 and state else "unknown"


def origin(url: str) -> tuple[str, str, int]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.username is not None or parsed.password is not None or parsed.scheme not in {"http", "https"}:
        raise CrossOriginRedirectError("redirect target has an unsafe origin")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise CrossOriginRedirectError("redirect target has an invalid port") from exc
    return parsed.scheme.lower(), (parsed.hostname or "").lower(), port


class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, allowed_origin: tuple[str, str, int], maximum: int) -> None:
        super().__init__()
        self.allowed_origin = allowed_origin
        self.max_redirections = maximum

    def redirect_request(self, req: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> urllib.request.Request | None:
        target = urllib.parse.urljoin(req.full_url, newurl)
        if origin(target) != self.allowed_origin:
            raise CrossOriginRedirectError("cross-origin health redirect rejected")
        return super().redirect_request(req, fp, code, msg, headers, target)


def check_app(app: dict[str, Any]) -> dict[str, Any]:
    app_id = app["id"]
    unit = app["service_unit"]
    port = app["listen"]["port"]
    health = app["health"]
    url = f"http://127.0.0.1:{port}{health['path']}"
    timeout = health["timeout_seconds"]
    state = service_state(unit)
    port_open = False
    http_status: int | None = None
    error: str | None = None
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            port_open = True
    except OSError as exc:
        error = f"port check failed: {exc}"

    if port_open:
        handler = SameOriginRedirectHandler(origin(url), health["max_same_origin_redirects"])
        opener = urllib.request.build_opener(handler)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "wsl-app-health/1"})
            with opener.open(request, timeout=timeout) as response:
                http_status = response.status
        except urllib.error.HTTPError as exc:
            http_status = exc.code
            error = f"HTTP status {exc.code}"
        except (CrossOriginRedirectError, OSError, urllib.error.URLError) as exc:
            error = f"HTTP check failed: {exc}"

    healthy = state == "active" and port_open and http_status in health["expected_status"]
    return {
        "id": app_id,
        "healthy": healthy,
        "service_state": state,
        "port_open": port_open,
        "http_status": http_status,
        "error": error,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--app", help="check one registered app id")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument("--validate", action="store_true", help="validate the registry without checking apps")
    args = parser.parse_args()
    try:
        apps = [app for app in load_registry(args.registry) if app["enabled"]]
        if args.validate:
            return 0
        if args.app:
            apps = [app for app in apps if app["id"] == args.app]
            if not apps:
                raise RegistryError(f"enabled app not found: {args.app}")
        results = [check_app(app) for app in apps]
    except RegistryError as exc:
        print(f"registry error: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps({"healthy": all(item["healthy"] for item in results), "apps": results}))
    else:
        for result in results:
            status = "OK" if result["healthy"] else "FAIL"
            detail = (
                f"service={result['service_state']} port={'open' if result['port_open'] else 'closed'} "
                f"http={result['http_status'] if result['http_status'] is not None else '-'}"
            )
            if result["error"]:
                detail += f" error={result['error']}"
            print(f"{status} {result['id']} {detail}")
    return 0 if all(item["healthy"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
