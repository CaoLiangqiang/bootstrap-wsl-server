# Scheduled Project Maintenance

This optional layer separates four kinds of state: a mutable source checkout,
its fetched remote refs, an immutable staged release, and the production
`current` symlink. Fetching or staging is not deployment. The timer never runs
`pull`, `reset`, `checkout`, `merge`, or the versioned release switch.

## Registry policy

The top-level `sync_projects` array is optional. Missing or empty means no
projects are maintained. Each entry has an explicit project ID, absolute source
and deploy paths, exact origin, timeout, retry limit, and one policy:

- `fetch-only` runs `git fetch --prune --no-recurse-submodules origin`, records
  the observed and fetched heads, and leaves the worktree unchanged. Use this
  default unless release staging is specifically approved.
- `stage-release` fetches one exact tag or full 40-character commit, confirms
  `expected_commit`, archives it into `deploy_root/releases`, and runs a tracked
  executable verification hook from that approved commit. It does not change
  `current`; a successful stage is only a candidate for operator review.
- `auto-deploy` is reserved so policy intent can be represented, but the
  executor rejects it. Enabling automatic switching requires a separate design
  and production release.

Example default entry:

```json
{
  "schema_version": 1,
  "sync_projects": [
    {
      "id": "example-app",
      "enabled": true,
      "source_path": "/srv/sources/example-app",
      "source_origin": "git@example.invalid:group/example-app.git",
      "remote": "origin",
      "deploy_root": "/srv/apps/example-app",
      "sync_policy": "fetch-only",
      "timeout_seconds": 120,
      "retries": 2
    }
  ],
  "apps": []
}
```

For `stage-release`, add this policy object only after reviewing the target and
hook. A moving branch name is never accepted:

```json
{
  "sync_policy": "stage-release",
  "stage_release": {
    "kind": "tag",
    "value": "v1.2.3",
    "expected_commit": "0123456789abcdef0123456789abcdef01234567",
    "release_id": "1.2.3-0123456789ab",
    "verify_hook": ".wsl-server/stage-release",
    "verify_args": ["--offline"]
  }
}
```

The hook is code from the approved commit and must be reviewed before use. It
must not require secrets or modify shared data. Dependencies and build output
needed by production belong inside the staged release; persistent data, config,
secrets, and logs remain under `shared`.

## Git authentication

Use a repository deploy key or machine identity granted read-only access by the
Git hosting service. Do not test read-only access by attempting a push. The
executor disables terminal and credential-manager prompts and forces SSH batch
mode with strict host-key checking. Prepare `known_hosts` and the credential
helper outside this repository. Registry origins may be SSH, SCP-style SSH, or
HTTPS without userinfo, passwords, query strings, or fragments; secrets must
never appear in the registry, unit, report, or logs.

The configured origin must exactly match the checkout's sole `origin` URL.
Linked worktrees and external Git directories are rejected so the systemd
sandbox can grant a stable, narrow write path to each repository-local `.git`.

## Render, install, and enable

Validate generated files in a temporary directory first:

```bash
bash scripts/install-project-sync.sh \
  --registry /ABSOLUTE/PATH/registry.json \
  --install-dir /ABSOLUTE/PATH/project-sync \
  --state-dir /ABSOLUTE/PATH/project-sync-state \
  --render-only /tmp/project-sync-render
```

Inspect the rendered service's `ReadWritePaths`, then repeat without
`--render-only` to install the script and user units. Installation reloads the
user manager but deliberately does not enable or start the timer. Enable it
only after registry review:

```bash
systemctl --user enable --now wsl-project-sync.timer
```

The timer runs after ten minutes, then every six hours with randomized delay.
One global lock prevents overlapping runs. Fetches have per-project timeouts
and zero to three retries. Logs contain only project ID, policy, and outcome;
Git URLs and stderr are not printed.

## Observe and approve

Run a non-mutating preflight or one selected project manually:

```bash
/ABSOLUTE/PATH/project-sync/sync-projects.py \
  --registry /ABSOLUTE/PATH/registry.json \
  --state-dir /ABSOLUTE/PATH/project-sync-state --dry-run
```

Each private `PROJECT_ID.json` report records check time, policy, observed HEAD,
fetched remote HEAD, ahead/behind, dirty status, update availability, staging
result, or a sanitized failure category. Reports are atomic and do not modify
the registry or appear in the Workbench API.

After a `stage-release` report succeeds, inspect `.release.json`, verify the
release contains no secrets or persistent data, and run application-specific
offline and health checks. Only then use `scripts/switch-versioned-release.sh`
as documented in `project-migration.md`; update registry deployment metadata
only after the health gate passes. Keep the previous known-good release for
rollback.
