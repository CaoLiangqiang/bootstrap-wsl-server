---
name: bootstrap-wsl-server
description: Apply the Phase 2 server extension after bootstrap-wsl-ai-dev has established a native WSL foundation. Configure, verify, operate, document, and troubleshoot WSL2 Ubuntu SSH using default NAT networking, Windows portproxy, a Private/LocalSubnet firewall rule, password and public-key authentication, startup automation, standalone host/client HTML manuals, and an optional loopback-only health workbench. Optionally add a Phase 2b platform for long-running loopback WebUI applications with a registry, health timers, an authenticated HTTPS gateway, client CA guidance, startup wake automation, and encrypted backup guidance. Use when Codex needs to extend a prepared WSL AI workstation into a LAN SSH or WebUI server, migrate a Windows WebUI project into WSL, generate administrator or client access manuals, enroll SSH public keys, change LAN ports, audit services, or safely roll back LAN access.
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
9. Always generate the standalone host and client manuals with `scripts/render-manuals.sh`; give the client file to access users without secrets or fixed LAN IPs.
10. Install the optional dashboard with `bash scripts/install-workbench.sh --windows-user WINDOWS_USER --distro DISTRO --ssh-port PORT`; this also refreshes both standalone manuals.
11. Test from the actual client with `BatchMode=yes`, `IdentitiesOnly=yes`, and `IdentityAgent=none`; do not confuse `Server accepts key` with completed authentication.
12. When the user requests hosted WebUIs, read `references/webui-apps.md` completely and apply Phase 2b only after SSH and the foundation are healthy. Render or install the shared operations baseline, register one loopback application, verify its health, configure the HTTPS gateway, apply the Windows relay, install the public CA on the actual client, and test the full browser workflow.
13. Treat each later WebUI as a separate application-owned service. Use a separate hostname by default; use a path prefix only after confirming the application supports that base path.
14. Read `references/operations.md` for normal administration or `references/troubleshooting.md` for failures.

## Success criteria

- WSL has a default route and a readable generated resolver.
- `ssh.service` is active and effective policy denies root while allowing the selected user.
- Windows listens on the chosen LAN port and forwards to `127.0.0.1:22`.
- The firewall rule is enabled only for Private networks and `LocalSubnet`.
- Password login works when enabled, and an explicitly selected private key completes a signed public-key login.
- The startup task wakes the selected WSL distribution after Windows logon.
- `wsl-server-host-manual.html` and `wsl-server-client-manual.html` exist with all template values resolved.
- The Phase 1 foundation remains unchanged: no new mirrored mode, global DNS override, Docker proxy rewrite, or Windows AI cleanup occurred during the server extension.
- When installed, the workbench and five-minute health timer are active and the dashboard is reachable only on `127.0.0.1:4173`.
- When Phase 2b is installed, every registered application and Caddy listener is loopback-only, each enabled health timer passes, and Windows has exactly one owned HTTPS relay with a `Private` and `LocalSubnet` firewall rule.
- The unauthenticated HTTPS request returns `401`, authenticated HTTPS reaches the expected application version or health endpoint, and the public CA fingerprint is verified on the actual client without distributing any private CA material.
- Any encrypted local backup fails when a required source is missing, passes `restic check`, and is described as a local recovery layer rather than disaster recovery.

## Resource routing

- Read `references/setup-runbook.md` for the complete installation sequence and shell boundaries.
- Read `references/base-integration.md` for the Phase 1 handoff and ownership contract.
- Read `references/operations.md` for startup, access logs, key enrollment, port changes, workbench use, and rollback.
- Read `references/troubleshooting.md` before changing SSH policy, WSL networking, DNS, firewall rules, or client keys.
- Read `references/webui-apps.md` before installing, exposing, backing up, migrating, or removing a managed WebUI application.
- Run `scripts/audit-wsl-server.sh` before changes and `scripts/verify-wsl-server.sh` after each layer.
- Run `scripts/configure-wsl-base.sh` only inside WSL and `scripts/Configure-WslSshLan.ps1` only from elevated Windows PowerShell.
- Use `scripts/add-ssh-public-key.sh` only with public key files.
- Run `scripts/render-manuals.sh` after the hostname, users, distribution, or SSH port changes.
- Use `scripts/install-workbench.sh` only after SSH and Windows forwarding are working.
- Use `scripts/install-webui-apps.sh` only when the user explicitly requests Phase 2b; use `--render-only` for review and testing before changing the live server.
- Run `scripts/self-test-webui-apps.sh` after changing the Phase 2b installer, registry, health checker, Caddy template, or systemd templates.
- Run `scripts/Configure-WslWebGatewayLan.ps1` only from elevated Windows PowerShell after the WSL gateway listener is healthy.
- Use `scripts/Configure-WslStartupTask.ps1` to add the optional passwordless S4U boot wake task; retain existing logon tasks until a maintenance-window cold-start test passes.
