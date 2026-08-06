---
name: bootstrap-wsl-server
description: Configure, verify, operate, and troubleshoot a Windows-hosted WSL2 Ubuntu SSH server using default NAT networking, Windows portproxy, a Private/LocalSubnet firewall rule, password and public-key authentication, startup automation, and an optional loopback-only health workbench. Use when Codex needs to reproduce this WSL server setup on another Windows computer, enroll SSH public keys, change the LAN SSH port, audit access logs, install the local workbench, diagnose WSL route or DNS failures, or safely roll back LAN access.
---

# Bootstrap WSL Server

Build the server in layers so each trust boundary remains visible: WSL services, Windows LAN forwarding, client authentication, then the optional local workbench.

## Safety rules

- Start with `scripts/audit-wsl-server.sh`; do not mutate networking until the current state is known.
- Keep WSL on default NAT unless the user explicitly requests and validates another mode. Do not create `.wslconfig` merely to make SSH reachable.
- Never request, read, print, copy, or commit passwords, tokens, or private keys. Accept only `.pub` files for key enrollment.
- Keep the Windows firewall limited to `Private` profiles and `LocalSubnet` unless the user explicitly defines a stronger external boundary.
- Bind the workbench only to `127.0.0.1`; never expose port `4173` through `portproxy`.
- Treat Docker reachability as independent from SSH and WSL routing. Do not change global DNS to fix a registry-specific block.
- Ask the user to enter sudo credentials and approve Windows UAC locally. Do not collect those credentials.
- Revalidate distribution name, usernames, port availability, Windows network profile, and LAN IP on every new computer.

## Workflow

1. Read `references/setup-runbook.md` completely before configuring a new machine.
2. Run `bash scripts/audit-wsl-server.sh` and resolve any missing default route or resolver before installation.
3. Configure `/etc/wsl.conf` with `scripts/configure-wsl-base.sh`; preserve unrelated sections. After changes, require `wsl --shutdown` from Windows PowerShell.
4. Configure OpenSSH with `sudo bash scripts/configure-wsl-sshd.sh --user USER`. Keep both password and public-key authentication only when the user requests both.
5. Copy `scripts/Configure-WslSshLan.ps1` to Windows and run it from elevated PowerShell with the confirmed distribution and LAN port.
6. Verify Linux and Windows layers with `bash scripts/verify-wsl-server.sh` and the PowerShell status commands in the runbook.
7. Enroll only a public key file with `bash scripts/add-ssh-public-key.sh USER.pub`; return its fingerprint to the user.
8. Install the optional dashboard with `bash scripts/install-workbench.sh --windows-user WINDOWS_USER --distro DISTRO --ssh-port PORT`.
9. Test from the actual client with `BatchMode=yes`, `IdentitiesOnly=yes`, and `IdentityAgent=none`; do not confuse `Server accepts key` with completed authentication.
10. Read `references/operations.md` for normal administration or `references/troubleshooting.md` for failures.

## Success criteria

- WSL has a default route and a readable generated resolver.
- `ssh.service` is active and effective policy denies root while allowing the selected user.
- Windows listens on the chosen LAN port and forwards to `127.0.0.1:22`.
- The firewall rule is enabled only for Private networks and `LocalSubnet`.
- Password login works when enabled, and an explicitly selected private key completes a signed public-key login.
- The startup task wakes the selected WSL distribution after Windows logon.
- When installed, the workbench and five-minute health timer are active and the dashboard is reachable only on `127.0.0.1:4173`.

## Resource routing

- Read `references/setup-runbook.md` for the complete installation sequence and shell boundaries.
- Read `references/operations.md` for startup, access logs, key enrollment, port changes, workbench use, and rollback.
- Read `references/troubleshooting.md` before changing SSH policy, WSL networking, DNS, firewall rules, or client keys.
- Run `scripts/audit-wsl-server.sh` before changes and `scripts/verify-wsl-server.sh` after each layer.
- Run `scripts/configure-wsl-base.sh` only inside WSL and `scripts/Configure-WslSshLan.ps1` only from elevated Windows PowerShell.
- Use `scripts/add-ssh-public-key.sh` only with public key files.
- Use `scripts/install-workbench.sh` only after SSH and Windows forwarding are working.
