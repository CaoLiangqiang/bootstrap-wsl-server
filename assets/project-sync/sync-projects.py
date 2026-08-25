#!/usr/bin/env python3
"""Fetch registered Git projects and optionally stage an approved release."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
from datetime import datetime, timezone
from typing import Any


APP_ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
RELEASE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/+\-]{0,127}$")
SAFE_PATH_RE = re.compile(r"^/[A-Za-z0-9._+@/-]+$")
MAX_REGISTRY_BYTES = 1024 * 1024


class SyncError(RuntimeError):
    pass


class CommandFailure(SyncError):
    def __init__(self, category: str) -> None:
        super().__init__(category)
        self.category = category


def fail(message: str) -> None:
    raise SyncError(message)


def valid_text(value: Any, context: str, maximum: int = 4096) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= maximum:
        fail(f"{context} must be a non-empty string")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail(f"{context} contains a control character")
    return value


def valid_absolute_path(value: Any, context: str) -> pathlib.Path:
    text = valid_text(value, context)
    path = pathlib.Path(text)
    if (
        not path.is_absolute()
        or text == "/"
        or not SAFE_PATH_RE.fullmatch(text)
        or "//" in text
        or any(part in {".", ".."} for part in path.parts)
    ):
        fail(f"{context} must be a safe absolute path")
    return path


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def valid_origin(value: Any, context: str) -> str:
    origin = valid_text(value, context, 2048)
    if os.environ.get("WSL_PROJECT_SYNC_ALLOW_FILE_ORIGIN") == "1":
        parsed_file = urllib.parse.urlsplit(origin)
        if parsed_file.scheme == "file" and parsed_file.path.startswith("/"):
            return origin
    if re.fullmatch(r"[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s]+", origin):
        return origin
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme not in {"https", "ssh"} or not parsed.hostname:
        fail(f"{context} must be an HTTPS, SSH, or SCP-style Git URL")
    if parsed.password is not None or parsed.query or parsed.fragment:
        fail(f"{context} must not contain credentials, a query, or a fragment")
    if parsed.scheme == "https" and parsed.username is not None:
        fail(f"{context} must not contain HTTPS userinfo")
    return origin


def valid_hook(value: Any, context: str) -> str:
    hook = valid_text(value, context, 256)
    path = pathlib.PurePosixPath(hook)
    if path.is_absolute() or ".." in path.parts or hook.endswith("/"):
        fail(f"{context} must be a safe relative path")
    return hook


def valid_tag(value: str) -> bool:
    if not TAG_RE.fullmatch(value) or value.startswith("refs/"):
        return False
    if value.endswith((".", "/", ".lock")) or ".." in value or "@{" in value or "//" in value:
        return False
    return all(part and not part.startswith(".") and not part.endswith(".lock") for part in value.split("/"))


def validate_selector(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{context} must be an object")
    required = {"kind", "value", "expected_commit", "release_id", "verify_hook", "verify_args"}
    if set(value) != required:
        fail(f"{context} keys differ")
    kind = value["kind"]
    selector = valid_text(value["value"], f"{context}.value", 128)
    expected = valid_text(value["expected_commit"], f"{context}.expected_commit", 40)
    release_id = valid_text(value["release_id"], f"{context}.release_id", 128)
    if kind not in {"tag", "commit"}:
        fail(f"{context}.kind must be tag or commit")
    if kind == "tag" and not valid_tag(selector):
        fail(f"{context}.value is not a safe exact tag")
    if kind == "commit" and not COMMIT_RE.fullmatch(selector):
        fail(f"{context}.value must be a full commit")
    if not COMMIT_RE.fullmatch(expected) or (kind == "commit" and selector != expected):
        fail(f"{context}.expected_commit is invalid")
    if not RELEASE_RE.fullmatch(release_id):
        fail(f"{context}.release_id is invalid")
    valid_hook(value["verify_hook"], f"{context}.verify_hook")
    args = value["verify_args"]
    if not isinstance(args, list) or len(args) > 32:
        fail(f"{context}.verify_args must be an array")
    for index, argument in enumerate(args):
        valid_text(argument, f"{context}.verify_args[{index}]", 1024)
    return value


def validate_project(value: Any, context: str) -> dict[str, Any]:
    required = {
        "id", "enabled", "source_path", "source_origin", "remote", "deploy_root",
        "sync_policy", "timeout_seconds", "retries",
    }
    optional = {"stage_release"}
    if not isinstance(value, dict) or required - set(value) or set(value) - required - optional:
        fail(f"{context} contains missing or unknown keys")
    project_id = valid_text(value["id"], f"{context}.id", 32)
    if not APP_ID_RE.fullmatch(project_id):
        fail(f"{context}.id is invalid")
    if type(value["enabled"]) is not bool:
        fail(f"{context}.enabled must be boolean")
    valid_absolute_path(value["source_path"], f"{context}.source_path")
    valid_absolute_path(value["deploy_root"], f"{context}.deploy_root")
    valid_origin(value["source_origin"], f"{context}.source_origin")
    if value["remote"] != "origin":
        fail(f"{context}.remote must be origin")
    if value["sync_policy"] not in {"fetch-only", "stage-release", "auto-deploy"}:
        fail(f"{context}.sync_policy is invalid")
    if type(value["timeout_seconds"]) is not int or not 5 <= value["timeout_seconds"] <= 900:
        fail(f"{context}.timeout_seconds must be from 5 to 900")
    if type(value["retries"]) is not int or not 0 <= value["retries"] <= 3:
        fail(f"{context}.retries must be from 0 to 3")
    if value["sync_policy"] == "stage-release":
        if "stage_release" not in value:
            fail(f"{context}.stage_release is required")
        validate_selector(value["stage_release"], f"{context}.stage_release")
    elif "stage_release" in value:
        fail(f"{context}.stage_release is allowed only for stage-release")
    return value


def load_projects(path: pathlib.Path) -> list[dict[str, Any]]:
    if path.stat().st_size > MAX_REGISTRY_BYTES:
        fail("registry is larger than 1 MiB")
    try:
        document = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=strict_object
        )
    except SyncError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SyncError("registry cannot be read") from exc
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        fail("registry schema_version must be 1")
    projects = document.get("sync_projects", [])
    if not isinstance(projects, list):
        fail("sync_projects must be an array")
    result: list[dict[str, Any]] = []
    ids: set[str] = set()
    for index, project in enumerate(projects):
        validated = validate_project(project, f"sync_projects[{index}]")
        if validated["id"] in ids:
            fail(f"duplicate sync project id: {validated['id']}")
        ids.add(validated["id"])
        result.append(validated)
    return result


def command_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GCM_INTERACTIVE"] = "Never"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
    return environment


def classify_failure(stderr: str, timed_out: bool = False) -> str:
    if timed_out:
        return "timeout"
    lowered = stderr.lower()
    if "permission denied" in lowered or "authentication failed" in lowered:
        return "authentication"
    if "could not resolve" in lowered or "unable to access" in lowered or "connection" in lowered:
        return "network"
    if "not found" in lowered or "couldn't find remote ref" in lowered:
        return "not-found"
    return "git-failed"


def run(command: list[str], timeout_seconds: int, cwd: pathlib.Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=command_environment(),
            text=True,
            capture_output=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise CommandFailure(classify_failure("", timed_out=True)) from exc
    if result.returncode != 0:
        raise CommandFailure(classify_failure(result.stderr))
    return result.stdout.strip()


def git(source: pathlib.Path, timeout_seconds: int, *args: str) -> str:
    return run(["git", "-C", str(source), *args], timeout_seconds)


def fetch_with_retry(project: dict[str, Any], *refspecs: str) -> None:
    source = pathlib.Path(project["source_path"])
    command = ["fetch", "--prune", "--no-recurse-submodules", "origin", *refspecs]
    last_failure: CommandFailure | None = None
    for attempt in range(project["retries"] + 1):
        try:
            git(source, project["timeout_seconds"], *command)
            return
        except CommandFailure as exc:
            last_failure = exc
            if attempt < project["retries"]:
                time.sleep(min(2**attempt, 4))
    assert last_failure is not None
    raise last_failure


def verify_repository(project: dict[str, Any]) -> pathlib.Path:
    source = pathlib.Path(project["source_path"])
    if not source.is_dir() or source.is_symlink():
        fail("source path is missing or unsafe")
    inside = git(source, project["timeout_seconds"], "rev-parse", "--is-inside-work-tree")
    if inside != "true":
        fail("source path is not a Git worktree")
    git_directory = source / ".git"
    if not git_directory.is_dir() or git_directory.is_symlink():
        fail("source must use a repository-local .git directory")
    origins = git(source, project["timeout_seconds"], "remote", "get-url", "--all", "origin").splitlines()
    if origins != [project["source_origin"]]:
        fail("configured origin does not exactly match the repository")
    return source


def repository_observation(source: pathlib.Path, project: dict[str, Any]) -> dict[str, Any]:
    timeout_seconds = project["timeout_seconds"]
    observed = git(source, timeout_seconds, "rev-parse", "HEAD")
    dirty = bool(git(source, timeout_seconds, "status", "--porcelain"))
    remote = None
    try:
        remote = git(source, timeout_seconds, "rev-parse", "FETCH_HEAD")
    except CommandFailure:
        pass
    ahead = behind = None
    if remote and COMMIT_RE.fullmatch(remote):
        counts = git(source, timeout_seconds, "rev-list", "--left-right", "--count", f"HEAD...{remote}")
        ahead, behind = (int(item) for item in counts.split())
    return {
        "observed_head": observed,
        "remote_head": remote,
        "has_update": bool(remote and remote != observed),
        "ahead": ahead,
        "behind": behind,
        "worktree_dirty": dirty,
    }


def safe_extract(archive: pathlib.Path, destination: pathlib.Path) -> None:
    with tarfile.open(archive, "r") as bundle:
        destination_root = destination.resolve()
        for member in bundle.getmembers():
            if not (member.isfile() or member.isdir()):
                fail("release archive contains an unsupported entry type")
            target = (destination / member.name).resolve()
            if destination_root != target and destination_root not in target.parents:
                fail("release archive contains an unsafe path")
        bundle.extractall(destination)


def stage_release(source: pathlib.Path, project: dict[str, Any]) -> dict[str, Any]:
    selector = project["stage_release"]
    timeout_seconds = project["timeout_seconds"]
    if selector["kind"] == "tag":
        ref = f"refs/tags/{selector['value']}"
        sync_ref = f"refs/wsl-project-sync/{project['id']}/{selector['release_id']}"
        fetch_with_retry(project, f"{ref}:{sync_ref}")
        commit = git(source, timeout_seconds, "rev-parse", f"{sync_ref}^{{commit}}")
    else:
        fetch_with_retry(project, selector["value"])
        commit = git(source, timeout_seconds, "rev-parse", "FETCH_HEAD^{commit}")
    if commit != selector["expected_commit"]:
        fail("approved release target does not match expected_commit")

    hook = selector["verify_hook"]
    tree_entry = git(source, timeout_seconds, "ls-tree", commit, "--", hook)
    if not tree_entry.startswith("100755 blob "):
        fail("verify hook must be an executable file tracked by the approved commit")

    deploy_root = pathlib.Path(project["deploy_root"])
    releases = deploy_root / "releases"
    if not releases.is_dir() or releases.is_symlink():
        fail("deploy releases directory is missing or unsafe")
    destination = releases / selector["release_id"]
    metadata = {
        "release_id": selector["release_id"],
        "git_commit": commit,
        "source_origin": project["source_origin"],
        "selector": {"kind": selector["kind"], "value": selector["value"]},
        "staged_at": datetime.now(timezone.utc).isoformat(),
        "staged_by": "wsl-project-sync",
    }
    if destination.exists() or destination.is_symlink():
        if not destination.is_dir() or destination.is_symlink():
            fail("release destination already exists and is unsafe")
        try:
            existing = json.loads((destination / ".release.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SyncError("release destination already exists without valid metadata") from exc
        if existing.get("release_id") != selector["release_id"] or existing.get("git_commit") != commit:
            fail("release destination conflicts with the approved commit")
        return {"release_id": selector["release_id"], "commit": commit, "result": "already-staged"}

    current = deploy_root / "current"
    current_before = os.readlink(current) if current.is_symlink() else None
    stage = pathlib.Path(tempfile.mkdtemp(prefix=f".stage-{project['id']}.", dir=releases))
    try:
        archive = stage / ".source.tar"
        run(["git", "-C", str(source), "archive", "--format=tar", "--output", str(archive), commit], timeout_seconds)
        safe_extract(archive, stage)
        archive.unlink()
        hook_path = stage / hook
        if not hook_path.is_file() or hook_path.is_symlink() or not os.access(hook_path, os.X_OK):
            fail("staged verify hook is missing or unsafe")
        run([str(hook_path), *selector["verify_args"]], timeout_seconds, cwd=stage)
        (stage / ".release.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        os.chmod(stage / ".release.json", stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
        os.rename(stage, destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    current_after = os.readlink(current) if current.is_symlink() else None
    if current_before != current_after:
        fail("current changed while staging the release")
    return {"release_id": selector["release_id"], "commit": commit, "result": "staged"}


def write_report(state_dir: pathlib.Path, project_id: str, report: dict[str, Any]) -> None:
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)
    temporary = state_dir / f".{project_id}.{os.getpid()}.tmp"
    destination = state_dir / f"{project_id}.json"
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, destination)


def synchronize(project: dict[str, Any], state_dir: pathlib.Path) -> bool:
    report: dict[str, Any] = {
        "id": project["id"],
        "policy": project["sync_policy"],
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "status": "failed",
        "observed_head_before_fetch": None,
        "observed_head": None,
        "remote_head": None,
        "has_update": None,
        "ahead": None,
        "behind": None,
        "worktree_dirty": None,
    }
    try:
        if project["sync_policy"] == "auto-deploy":
            fail("auto-deploy is disabled")
        source = verify_repository(project)
        observed_before = git(source, project["timeout_seconds"], "rev-parse", "HEAD")
        report["observed_head_before_fetch"] = observed_before
        report["observed_head"] = observed_before
        report["worktree_dirty"] = bool(
            git(source, project["timeout_seconds"], "status", "--porcelain")
        )
        fetch_with_retry(project)
        report.update(repository_observation(source, project))
        if project["sync_policy"] == "stage-release":
            report["stage"] = stage_release(source, project)
        report["status"] = "ok"
    except CommandFailure as exc:
        report["failure"] = exc.category
    except SyncError as exc:
        report["failure"] = str(exc)
    write_report(state_dir, project["id"], report)
    print(f"SYNC_{report['status'].upper()} id={project['id']} policy={project['sync_policy']}")
    return report["status"] == "ok"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=pathlib.Path, required=True)
    parser.add_argument("--state-dir", type=pathlib.Path, required=True)
    parser.add_argument("--project")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        if not args.registry.is_absolute() or not args.state_dir.is_absolute():
            fail("registry and state paths must be absolute")
        projects = load_projects(args.registry)
        if args.project:
            projects = [project for project in projects if project["id"] == args.project]
            if not projects:
                fail("project is not registered")
        if args.validate:
            return 0
        enabled = [project for project in projects if project["enabled"]]
        if args.dry_run:
            for project in enabled:
                verify_repository(project)
                print(f"SYNC_DRY_RUN_OK id={project['id']} policy={project['sync_policy']}")
            return 0
        args.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_path = args.state_dir / ".sync.lock"
        with lock_path.open("a+", encoding="utf-8") as lock:
            os.chmod(lock_path, 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("SYNC_ALREADY_RUNNING")
                return 0
            success = all([synchronize(project, args.state_dir) for project in enabled])
            return 0 if success else 1
    except (OSError, SyncError) as exc:
        print(f"sync configuration error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
