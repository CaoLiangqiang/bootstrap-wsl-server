# bootstrap-wsl-server

`bootstrap-wsl-server` is a Phase 2 WSL2 server extension for a workstation
prepared by [`bootstrap-wsl-ai-dev`](https://github.com/CaoLiangqiang/bootstrap-wsl-ai-dev).
It turns a native Ubuntu WSL2 instance into an operable server while keeping
the trust boundaries explicit:

- WSL stays on default NAT with `systemd` as PID 1.
- Windows owns LAN exposure: portproxy and a `Private`/`LocalSubnet` firewall
  rule forward SSH and the authenticated HTTPS gateway into WSL loopback.
- OpenSSH is a system service; applications and the Workbench use systemd user
  units. The Workbench is a local-only console on `127.0.0.1:4173` and is never
  a LAN endpoint.
- WebUI applications are registered by metadata, health-checked on loopback,
  and exposed through Caddy Basic Auth and internal TLS.
- Production application code is separate from its source checkout. Releases
  use `releases/<id>`, `shared`, and an atomic `current` symlink; switching is
  health-gated and automatically rolls back on failure.

This is the formal delivered product shape: a reusable Phase 2 server Skill and
its shell, PowerShell, Python, systemd, Caddy, and standalone HTML assets. It
does not contain a business application or a hosted SaaS control plane. A
developer supplies an application repository, service unit, health endpoint,
secrets through approved local paths, and the current Windows host parameters;
the Skill renders machine-specific configuration and keeps application
listeners loopback-only behind the authenticated gateway.

## Supported Environment

Use Ubuntu on WSL2 with a recent Windows 11 host, systemd support, Bash,
Python 3.10 or newer, Node.js for the Workbench, `curl`, and GNU coreutils (`readlink`,
`mv`, and `date`) for versioned switching. Phase 2b requires Caddy 2.6 or newer.
Windows PowerShell scripts must run from an elevated PowerShell session when
they change portproxy, firewall, startup, or watchdog state. The selected WSL
user must exist, have a default route and generated resolver, and have linger
enabled when user services must run without an interactive login.

## Install And Operate

Read [`SKILL.md`](SKILL.md) for agent routing and the references for the
operator workflow. The normal sequence is:

```bash
bash scripts/audit-wsl-server.sh
bash scripts/verify-wsl-server.sh WSL_USER
bash scripts/render-manuals.sh --wsl-user WSL_USER \
  --windows-user WINDOWS_USER --windows-hostname WINDOWS_HOSTNAME \
  --distro Ubuntu --ssh-port 2222
```

Use `references/setup-runbook.md` for first installation, `references/operations.md`
for daily operations, and `references/project-migration.md` for application
migration. Render the optional WebUI layer with `scripts/install-webui-apps.sh
--render-only` before any live installation.

Optional project maintenance is registry-driven and disabled until
`sync_projects` entries are added and its user timer is explicitly enabled.
The default `fetch-only` policy updates remote refs without changing the source
worktree or production deployment. `stage-release` can prepare one approved,
immutable tag or full commit under `releases`, but never changes `current`.
`auto-deploy` is reserved in the schema and deliberately rejected. See
[`references/project-sync.md`](references/project-sync.md) for the registry,
render-only installation, reports, and deploy-key boundaries.

## Upgrade And Rollback

For each application, stage a clean commit as an immutable release with
release-local dependencies and shared links for configuration, databases,
uploads, reports, logs, and runtime state. Then switch only the named services:

```bash
bash scripts/switch-versioned-release.sh \
  --deploy-root /home/SERVER_USER/wsl-server/apps/APP_ID \
  --release-id VERSION-COMMIT \
  --service APP_ID.service \
  --health-url http://127.0.0.1:APP_PORT/HEALTH_PATH
```

The command requires the former release to be healthy, atomically updates
`current`, waits for every health URL, and restores the former target if a
restart or health gate fails. Update registry metadata only after health passes.
Keep at least current and previous known-good releases. A release is not a Git
mirror: the source checkout, any bare/mirror repository, and the deployment
copy are separate objects with separate ownership.

## Boundaries And Limits

The server extension does not own Phase 1 AI tooling, application business
code, application secrets, databases, gateway credentials, private CA keys,
Windows user passwords, or disaster recovery. The registry stores paths and
operational metadata, never secret values. Client browser acceptance must
verify the public CA fingerprint, authentication, and the real workflow; a
local `curl` check alone is insufficient. The Workbench trusts the local
Windows administrator and must remain loopback-only.

This repository currently has no license file. Public source availability does
not by itself grant reuse, modification, or redistribution rights; contact the
repository owner before use outside the owner's environment.

## Validation

Run the repository self-tests after changing templates or scripts:

```bash
bash scripts/self-test-webui-apps.sh
bash scripts/self-test-project-sync.sh
bash scripts/self-test.sh
```

The scripts also exercise render-only installation, registry validation,
loopback and redirect checks, project-sync fixtures, generated manuals, SSH key
enrollment, and the versioned-release dry-run. Live changes require the
preflight, backup, health, rollback, and client acceptance evidence described
in the references.
