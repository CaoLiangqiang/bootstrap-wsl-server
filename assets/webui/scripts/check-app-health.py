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
RELEASE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
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


def valid_absolute_path(value: Any, context: str) -> str:
    path = valid_text(value, context, 4096)
    if not path.startswith("/") or any(char.isspace() for char in path):
        raise RegistryError(f"{context} must be an absolute path without whitespace")
    return path.rstrip("/") or "/"


def valid_public_port(value: Any, context: str) -> int:
    if type(value) is not int or not 1 <= value <= 65535:
        raise RegistryError(f"{context} must be an integer from 1 to 65535")
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


def valid_health_url(value: Any, port: int, context: str) -> str:
    url = valid_text(value, context, 1024)
    parsed = urllib.parse.urlsplit(url)
    try:
        parsed_port = parsed.port
    except ValueError as exc:
        raise RegistryError(f"{context} has an invalid port") from exc
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or parsed_port != port
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise RegistryError(f"{context} must match the registered loopback port")
    valid_health_path(parsed.path)
    return url


def load_registry(path: Path) -> list[dict[str, Any]]:
    try:
        if path.stat().st_size > MAX_REGISTRY_BYTES:
            raise RegistryError("registry is larger than 1 MiB")
        document = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    except RegistryError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RegistryError(f"cannot read registry {path}: {exc}") from exc

    if not isinstance(document, dict):
        raise RegistryError("registry must be an object")
    root = document
    root_keys = set(root)
    if root_keys - {"schema_version", "gateway", "apps"} or {"schema_version", "apps"} - root_keys:
        raise RegistryError("registry contains missing or unknown keys")
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        raise RegistryError("schema_version must be integer 1")

    gateway_port: int | None = None
    if "gateway" in root:
        gateway = require_keys(root["gateway"], {"hostname", "listen"}, "gateway")
        valid_hostname(gateway["hostname"])
        gateway_listen = require_keys(root["gateway"]["listen"], {"host", "port"}, "gateway.listen")
        if gateway_listen["host"] != "127.0.0.1":
            raise RegistryError("gateway.listen.host must be 127.0.0.1")
        gateway_port = valid_port(gateway_listen["port"], "gateway.listen.port")

    if not isinstance(root["apps"], list) or not root["apps"]:
        raise RegistryError("apps must be a non-empty array")
    ids: set[str] = set()
    ports = {gateway_port} if gateway_port is not None else set()
    apps: list[dict[str, Any]] = []
    for index, raw_app in enumerate(root["apps"]):
        context = f"apps[{index}]"
        required_app_keys = {"id", "display_name", "enabled", "service_unit", "listen", "health"}
        optional_app_keys = {
            "source_path", "version", "git_commit", "deployment", "gateway",
            "secrets", "persistent_data", "notes", "exposure",
        }
        if not isinstance(raw_app, dict) or required_app_keys - set(raw_app) or set(raw_app) - required_app_keys - optional_app_keys:
            raise RegistryError(f"{context} contains missing or unknown keys")
        app = raw_app
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
        if "source_path" in app:
            valid_absolute_path(app["source_path"], f"{context}.source_path")
        if "version" in app:
            valid_text(app["version"], f"{context}.version", 64)
        commit: str | None = None
        if "git_commit" in app:
            commit = valid_text(app["git_commit"], f"{context}.git_commit", 40)
            if not COMMIT_RE.fullmatch(commit):
                raise RegistryError(f"{context}.git_commit must be a full lowercase Git commit")
        if "deployment" in app:
            if not {"source_path", "version", "git_commit"} <= set(app):
                raise RegistryError(f"{context}.deployment requires source_path, version, and git_commit")
            deployment = app["deployment"]
            deployment_required = {
                "strategy", "deploy_root", "current_path", "current_release",
                "release_path", "source_commit",
            }
            deployment_optional = {
                "previous_release", "previous_release_path", "rollback_unit_backup",
                "rollback_registry_backup",
            }
            if not isinstance(deployment, dict):
                raise RegistryError(f"{context}.deployment must be an object")
            deployment_keys = set(deployment)
            missing = sorted(deployment_required - deployment_keys)
            extra = sorted(deployment_keys - deployment_required - deployment_optional)
            if missing or extra:
                raise RegistryError(
                    f"{context}.deployment keys differ: missing={missing} unknown={extra}"
                )
            if deployment["strategy"] != "versioned-current-symlink":
                raise RegistryError(f"{context}.deployment.strategy is unsupported")
            deploy_root = valid_absolute_path(
                deployment["deploy_root"], f"{context}.deployment.deploy_root"
            )
            release_id = valid_text(
                deployment["current_release"], f"{context}.deployment.current_release", 128
            )
            if not RELEASE_RE.fullmatch(release_id):
                raise RegistryError(f"{context}.deployment.current_release is invalid")
            if deployment["current_path"] != f"{deploy_root}/current":
                raise RegistryError(f"{context}.deployment.current_path must match deploy_root")
            if deployment["release_path"] != f"{deploy_root}/releases/{release_id}":
                raise RegistryError(f"{context}.deployment.release_path must match current_release")
            if deployment["source_commit"] != commit:
                raise RegistryError(f"{context}.deployment.source_commit must match git_commit")
            has_previous_release = "previous_release" in deployment
            has_previous_path = "previous_release_path" in deployment
            if has_previous_release != has_previous_path:
                raise RegistryError(
                    f"{context}.deployment previous release fields must be provided together"
                )
            if has_previous_release:
                previous_release = valid_text(
                    deployment["previous_release"],
                    f"{context}.deployment.previous_release",
                    128,
                )
                if not RELEASE_RE.fullmatch(previous_release) or previous_release == release_id:
                    raise RegistryError(f"{context}.deployment.previous_release is invalid")
                if deployment["previous_release_path"] != f"{deploy_root}/releases/{previous_release}":
                    raise RegistryError(
                        f"{context}.deployment.previous_release_path must match previous_release"
                    )
            for backup_key in ("rollback_unit_backup", "rollback_registry_backup"):
                if backup_key in deployment:
                    valid_absolute_path(deployment[backup_key], f"{context}.deployment.{backup_key}")

        listen = require_keys(app["listen"], {"host", "port"}, f"{context}.listen")
        if listen["host"] != "127.0.0.1":
            raise RegistryError(f"{context}.listen.host must be 127.0.0.1")
        port = valid_port(listen["port"], f"{context}.listen.port")
        if port in ports or port == 4173:
            raise RegistryError(f"{context}.listen.port conflicts with a reserved or registered port")
        ports.add(port)

        health = app["health"]
        if not isinstance(health, dict):
            raise RegistryError(f"{context}.health must be an object")
        if set(health) == {"path", "expected_status", "timeout_seconds", "max_same_origin_redirects"}:
            valid_health_path(health["path"])
        elif set(health) == {"url", "expected_status", "timeout_seconds"}:
            valid_health_url(health["url"], port, f"{context}.health.url")
        else:
            raise RegistryError(f"{context}.health contains missing or unknown keys")
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
        if "max_same_origin_redirects" in health:
            redirects = health["max_same_origin_redirects"]
            if type(redirects) is not int or not 0 <= redirects <= 5:
                raise RegistryError(f"{context}.health.max_same_origin_redirects must be from 0 to 5")

        if "gateway" in app:
            required_gateway_keys = {"hostname", "windows_listen_port", "wsl_listen", "tls", "authentication"}
            optional_gateway_keys = {
                "alternate_hostnames", "firewall_profile", "remote_scope", "client_ca_certificate",
                "client_ca_sha256", "pilot",
            }
            if not isinstance(app["gateway"], dict) or required_gateway_keys - set(app["gateway"]) or set(app["gateway"]) - required_gateway_keys - optional_gateway_keys:
                raise RegistryError(f"{context}.gateway contains missing or unknown keys")
            app_gateway = app["gateway"]
            valid_hostname(app_gateway["hostname"])
            valid_public_port(
                app_gateway["windows_listen_port"],
                f"{context}.gateway.windows_listen_port",
            )
            wsl_listen = valid_text(app_gateway["wsl_listen"], f"{context}.gateway.wsl_listen", 32)
            match = re.fullmatch(r"127\.0\.0\.1:([0-9]+)", wsl_listen)
            if not match:
                raise RegistryError(f"{context}.gateway.wsl_listen must use loopback")
            app_gateway_port = valid_port(int(match.group(1)), f"{context}.gateway.wsl_listen port")
            if gateway_port is not None and app_gateway_port != gateway_port:
                raise RegistryError(f"{context}.gateway.wsl_listen must match the loopback gateway")
            if app_gateway["tls"] != "internal-ca":
                raise RegistryError(f"{context}.gateway.tls must be internal-ca")
            if app_gateway["authentication"] != "basic":
                raise RegistryError(f"{context}.gateway.authentication must be basic")
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
    url = health.get("url") or f"http://127.0.0.1:{port}{health['path']}"
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
        handler = SameOriginRedirectHandler(origin(url), health.get("max_same_origin_redirects", 0))
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
