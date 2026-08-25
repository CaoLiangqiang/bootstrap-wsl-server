---
name: bootstrap-wsl-server
description: Apply the Phase 2 server extension after bootstrap-wsl-ai-dev has established a native WSL foundation. Configure, verify, operate, document, and troubleshoot WSL2 Ubuntu SSH using default NAT networking, Windows portproxy, a Private/LocalSubnet firewall rule, password and public-key authentication, startup automation, standalone host/client/project-migration HTML manuals, and an optional loopback-only health workbench. Optionally add a Phase 2b platform for long-running loopback WebUI applications with a registry, health timers, an authenticated HTTPS gateway, client CA guidance, startup wake automation, and encrypted backup guidance. Use when Codex needs to extend a prepared WSL AI workstation into a LAN SSH or WebUI server, migrate or hand off a Windows WebUI repository into WSL end to end, generate administrator, client, or project migration manuals, enroll SSH public keys, change LAN ports, audit services, or safely roll back LAN access.
---

# Bootstrap WSL Server

Build the server in layers so each trust boundary remains visible: WSL services, Windows LAN forwarding, client authentication, then the optional local workbench.

## Foundation dependency

Treat `bootstrap-wsl-ai-dev` as Phase 1 and this Skill as Phase 2. Read `references/base-integration.md` and, when both repositories are available, `../bootstrap-wsl-ai-dev/references/wsl-server-extension-contract.md` before changing anything. Do not repeat AI CLI migration, Windows AI cleanup, GitHub/GitLab client setup, Docker installation, or Explorer registry work here.

## Safety rules

- Start with the Phase 1 audit (`$bootstrap-wsl-ai-dev`) and then run `scripts/audit-wsl-server.sh`; do not mutate networking until the current state is known.
- Keep WSL on default NAT unless the user explicitly requests and validates another mode. Do not create `.wslconfig` merely to make SSH reachable.
- Never request, read, print, copy, or commit passwords, tokens, or private keys. Accept only `.pub` files for key enrollment.
- Keep the Windows firewall limited to `Private` profiles and `LocalSubnet` unless the user explicitly defines a stronger external boundary.
- Bind the workbench only to `127.0.0.1`; never expose port `4173` through `portproxy`.
- Bind every managed application and the optional WebUI gateway only to loopback inside WSL. Expose only the authenticated HTTPS gateway through Windows; never register or forward the workbench as an application.
- Give every user-facing WebUI one canonical lowercase URL in the form `https://APP_ID.SERVER_NAME.local/`; do not distribute WSL addresses, internal ports, `:8443`, or direct HTTP rollback ports.
- Store only secret paths in the WebUI registry. Keep plaintext credentials, password hashes, application `.env` files, Restic passwords, and Caddy CA private keys out of Git, chat, URLs, and logs.
- Keep an existing direct application port only as an explicitly documented pilot rollback. Remove it only after a real client browser passes TLS, CA trust, authentication, and full-function testing.
- Treat Docker reachability as independent from SSH and WSL routing. Do not change global DNS to fix a registry-specific block.
- Ask the user to enter sudo credentials and approve Windows UAC locally. Do not collect those credentials.
- Revalidate distribution name, usernames, port availability, Windows network profile, and LAN IP on every new computer.
- Read and preserve the foundation's `/etc/wsl.conf` `[interop]` and network sections. The server extension only verifies `[boot] systemd` and `[user] default`; its local `configure-wsl-base.sh` is a compatibility fallback, not the primary foundation workflow.

## Workflow

1. Read `references/setup-runbook.md` and `references/base-integration.md` completely before configuring a new machine.
2. Confirm the Phase 1 handoff: systemd is PID 1, the selected default user exists, WSL has a default route, and `/etc/resolv.conf` has a nameserver.
3. Run `bash scripts/audit-wsl-server.sh`; stop if the foundation is unhealthy. Do not enable mirrored networking to repair it.
4. If the foundation Skill is unavailable and only the shared WSL keys are missing, use `sudo bash scripts/configure-wsl-base.sh --user USER` as a compatibility fallback. Do not pass `--isolate-windows-path` when Phase 1 already owns PATH isolation.
5. Configure OpenSSH with `sudo bash scripts/configure-wsl-sshd.sh --user USER`. Keep both password and public-key authentication only when the user requests both.
6. Copy `scripts/Configure-WslSshLan.ps1` to Windows and run it from elevated PowerShell with the confirmed distribution and LAN port.
7. Verify Linux and Windows layers with `bash scripts/verify-wsl-server.sh` and the PowerShell status commands in the runbook.
8. Enroll only a public key file with `bash scripts/add-ssh-public-key.sh USER.pub`; return its fingerprint to the user.
9. Always generate the standalone host, client, and project migration manuals with `scripts/render-manuals.sh`; give the client and migration files to their intended users without secrets or fixed LAN IPs.
10. Install the optional dashboard with `bash scripts/install-workbench.sh --windows-user WINDOWS_USER --distro DISTRO --ssh-port PORT`; this also refreshes all three standalone manuals.
11. Test from the actual client with `BatchMode=yes`, `IdentitiesOnly=yes`, and `IdentityAgent=none`; do not confuse `Server accepts key` with completed authentication.
12. When the user requests a project migration, read `references/project-migration.md` completely, inventory the source project and choose a transfer method before changing the server.
   Stage each approved application commit under an application-owned
   `releases/RELEASE_ID` directory, keep secrets and persistent state under
   `shared`, and run services through a stable `current` symlink. Verify the
   former release before switching, use `scripts/switch-versioned-release.sh`
   for an atomic current update with health-gated automatic rollback, and keep
   at least the current and previous known-good releases. Do not run production
   services directly from the mutable source checkout.
13. When the user requests hosted WebUIs, read `references/webui-apps.md` completely and apply Phase 2b only after SSH and the foundation are healthy. Render or install the shared operations baseline, register one loopback application, verify its health, configure the HTTPS gateway, apply the Windows relay, install the public CA on the actual client, and test the full browser workflow.
14. Treat each later WebUI as a separate application-owned service. Use a separate hostname by default; use a path prefix only after confirming the application supports that base path.
15. When the user needs runtime recovery, install the optional Windows recovery watchdog from `references/webui-apps.md`; it wakes the selected WSL distribution and starts only explicitly configured user services before checking managed listeners, without restarting SSH or shutting down WSL.
16. Read `references/operations.md` for normal administration or `references/troubleshooting.md` for failures.
17. When the user requests scheduled Git maintenance, read
    `references/project-sync.md`. Start with `fetch-only`; treat source refs,
    staged releases, and the active `current` deployment as separate state.
    Never enable the timer implicitly, and never execute `auto-deploy`.

## Success criteria

- WSL has a default route and a readable generated resolver.
- `ssh.service` is active and effective policy denies root while allowing the selected user.
- Windows listens on the chosen LAN port and forwards to `127.0.0.1:22`.
- The firewall rule is enabled only for Private networks and `LocalSubnet`.
- Password login works when enabled, and an explicitly selected private key completes a signed public-key login.
- The startup task wakes the selected WSL distribution after Windows logon.
- `wsl-server-host-manual.html`, `wsl-server-client-manual.html`, and `wsl-server-project-migration-manual.html` exist with all template values resolved.
- The Phase 1 foundation remains unchanged: no new mirrored mode, global DNS override, Docker proxy rewrite, or Windows AI cleanup occurred during the server extension.
- When installed, the workbench and five-minute health timer are active and the dashboard is reachable only on `127.0.0.1:4173`.
- When enabled, the Windows recovery watchdog is owned by this Skill, runs at the configured interval (12 minutes by default), wakes WSL, and starts only its explicitly configured systemd user services before checking managed listeners.
- When Phase 2b is installed, every registered application and Caddy listener is loopback-only, each enabled health timer passes, and Windows has exactly one owned HTTPS relay with a `Private` and `LocalSubnet` firewall rule.
- Every enabled WebUI has a canonical gateway hostname aligned with its certificate and either managed DNS or an explicit client `hosts` mapping to the current Windows LAN IP.
- The unauthenticated HTTPS request returns `401`, authenticated HTTPS reaches the expected application version or health endpoint, and the public CA fingerprint is verified on the actual client without distributing any private CA material.
- Any encrypted local backup fails when a required source is missing, passes `restic check`, and is described as a local recovery layer rather than disaster recovery.

## Resource routing

- Read `references/setup-runbook.md` for the complete installation sequence and shell boundaries.
- Read `references/base-integration.md` for the Phase 1 handoff and ownership contract.
- Read `references/operations.md` for startup, access logs, key enrollment, port changes, workbench use, and rollback.
- Read `references/troubleshooting.md` before changing SSH policy, WSL networking, DNS, firewall rules, or client keys.
- Read `references/webui-apps.md` before installing, exposing, backing up, migrating, or removing a managed WebUI application.
- Read `references/project-migration.md` for the end-to-end source inventory, transfer, Linux adaptation, service, exposure, backup, acceptance, rollback, and handoff workflow.
- Read `references/project-sync.md` before adding registry-driven fetch or
  release staging. Use `scripts/install-project-sync.sh --render-only` first;
  installation must not enable or start the timer.
- Run `scripts/audit-wsl-server.sh` before changes and `scripts/verify-wsl-server.sh` after each layer.
- Run `scripts/configure-wsl-base.sh` only inside WSL and `scripts/Configure-WslSshLan.ps1` only from elevated Windows PowerShell.
- Use `scripts/add-ssh-public-key.sh` only with public key files.
- Run `scripts/render-manuals.sh` after the hostname, users, distribution, or SSH port changes.
- Use `scripts/install-workbench.sh` only after SSH and Windows forwarding are working.
- Use `scripts/install-webui-apps.sh` only when the user explicitly requests Phase 2b; use `--render-only` for review and testing before changing the live server.
- Use `scripts/switch-versioned-release.sh` only after staging immutable release
  metadata, release-local dependencies, shared data/config links, service units
  that reference `current`, and a tested former release. It switches no registry
  or gateway state; update those records only after the application is healthy.
- Run `scripts/self-test-webui-apps.sh` after changing the Phase 2b installer, registry, health checker, Caddy template, or systemd templates.
- Run `scripts/self-test-project-sync.sh` after changing the sync executor,
  registry sync schema, installer, or project-sync systemd units.
- Run `scripts/Configure-WslWebGatewayLan.ps1` only from elevated Windows PowerShell after the WSL gateway listener is healthy.
- Use `scripts/Configure-WslStartupTask.ps1` to add the optional passwordless S4U boot wake task; retain existing logon tasks until a maintenance-window cold-start test passes.
- Use `scripts/Configure-WslRecoveryWatchdog.ps1` for the optional periodic runtime wake check; inspect with `-Status` and remove only with `-Remove`. Keep its state file and task ownership intact.
