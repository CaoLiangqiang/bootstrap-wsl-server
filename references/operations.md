# WSL Server Operations

## Contents

1. Daily status
2. Access records
3. Public-key enrollment
4. Password and port management
5. Workbench and health history
6. Recovery and browser continuity
7. Manual regeneration and delivery
8. Client configuration
9. Rollback

## 1. Daily status

Inside WSL:

```bash
systemctl status ssh.service --no-pager
ss -ltn '( sport = :22 )'
ip route
cat /etc/resolv.conf
bash scripts/verify-wsl-server.sh USER
```

In Windows PowerShell:

```powershell
Get-NetIPConfiguration | Where-Object IPv4DefaultGateway
netsh interface portproxy show v4tov4
Get-NetTCPConnection -State Listen -LocalPort 2222
```

LAN addresses are normally dynamic. Give users the current Windows LAN IP or a locally managed DNS name; never publish the WSL NAT address as the stable endpoint.

## 2. Access records

Inside WSL:

```bash
journalctl -u ssh --since today --no-pager
journalctl -u ssh -f
```

Windows `portproxy` makes connections appear to WSL as `127.0.0.1`. Windows Firewall remains the source-network boundary, so preserve its `LocalSubnet` restriction.

## 3. Public-key enrollment

All enrolled keys map to the configured WSL account; this workflow does not
create a separate Linux account. Accept only an OpenSSH `.pub` file. From the
server's local browser, open `http://127.0.0.1:4173`, use **Access management →
Login public key**, verify the SHA256 fingerprint, and confirm.

The command-line fallback is:

```bash
bash scripts/add-ssh-public-key.sh /path/to/user.pub
ssh-keygen -lf ~/.ssh/authorized_keys
stat -c '%U:%G %a %n' ~/.ssh ~/.ssh/authorized_keys
```

Expected modes are `700` for `.ssh` and `600` for `authorized_keys`. Return the full SHA256 fingerprint to the user. Never accept a private key. Enrollment appends only and does not reload or restart `sshd`, so existing sessions remain connected.

The workbench has no independent authentication and trusts the local machine.
Keep it on `127.0.0.1`, never port-forward `4173`, and use the enrollment UI
only from the local administrator's browser. Each private-key holder receives
the full permissions of the shared WSL account.

Enrollment audit lines contain only the result, algorithm, fingerprint, and
loopback address:

```bash
journalctl --user -u wsl-server-workbench --since today | grep public-key-enrollment
```

To revoke a key, identify the exact fingerprint first, back up `authorized_keys`, remove only the corresponding complete line, and run `ssh-keygen -lf` again. Do not rewrite unrelated or malformed historical entries without explicit review.

## 4. Password and port management

Change the WSL password inside WSL:

```bash
passwd
```

Change the Windows LAN port from elevated PowerShell:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslSshLan.ps1" `
  -Distro Ubuntu -ListenPort 2223
```

The script removes only the previously recorded managed proxy before creating the new one. Update client SSH configuration after a port change.

## 5. Workbench and health history

```bash
systemctl --user status wsl-server-workbench --no-pager
systemctl --user restart wsl-server-workbench
journalctl --user -u wsl-server-workbench -f
systemctl --user list-timers wsl-server-workbench-health.timer
journalctl --user -u wsl-server-workbench-health.service --since today
curl -fsS http://127.0.0.1:4173/api/overview
```

Health files are stored under `~/.local/state/wsl-server-workbench` with private permissions. The timer runs about every five minutes and retains about seven days at that frequency.

The web process never receives passwords. Password changes open a terminal. Port changes open an elevated Windows PowerShell process and require UAC.

## 6. Recovery and browser continuity

For a long-running WebUI host, inspect the optional Windows runtime watchdog:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslRecoveryWatchdog.ps1" -Status
```

It wakes WSL every 12 minutes by default, idempotently starts only its configured
systemd user services, and then checks the managed Windows listener ports.
Each service unit retains its own `Restart=on-failure` policy. It does not restart SSH, run `wsl --shutdown`, or
forward the local workbench. Remove only the owned task with `-Remove`.

The workbench browser page polls its API about every 30 seconds, so a healthy
service continues to refresh data while the page remains open. A network/TCP disconnect cannot be
kept alive by the server; after recovery the browser may need to reconnect or
reload. The console is intentionally available only in the Windows server
host's local browser at `http://127.0.0.1:4173`.

The overview lists enabled WebUI applications that have a registered Windows
gateway hostname and listen port. It reads only display metadata from
`~/wsl-server/apps/registry.json`; internal application ports, secret paths,
credentials, and disabled or loopback-only applications are not returned to
the browser. Keep the registry gateway metadata aligned with the live Caddy
site and Windows HTTPS relay whenever an application hostname changes.

For versioned applications, treat the source checkout and production runtime as
separate objects. The registry records both `source_path` and a `deployment`
object containing `deploy_root`, `current_path`, `current_release`,
`release_path`, and the full source commit. After the first successful switch,
also record the paired optional fields `previous_release` and
`previous_release_path` for the retained known-good release. Confirm the live
unit and process resolve through `current` before reporting a deployment as
complete.

Stage and validate a new immutable release before switching it. Then run:

```bash
bash scripts/switch-versioned-release.sh \
  --deploy-root /home/SERVER_USER/wsl-server/apps/APP_ID \
  --release-id VERSION-COMMIT \
  --service APP_ID.service \
  --health-url http://127.0.0.1:APP_PORT/HEALTH_PATH
```

The script requires a healthy former release and health-gates the new release;
failure restores former `current` automatically. Update registry metadata only
after health succeeds. Keep at least current and previous known-good releases,
and never delete a release referenced by `current`, a running process, or the
documented rollback procedure. Secrets, databases, uploads, reports, and logs
remain under `shared` and are never copied into a release.

## 7. Manual regeneration and delivery

Regenerate the standalone manuals after changing any connection parameter:

```bash
bash scripts/render-manuals.sh \
  --windows-user WINDOWS_USER \
  --windows-hostname WINDOWS_HOSTNAME \
  --distro Ubuntu \
  --ssh-port 2222
```

Open the host manual locally:

```text
~/wsl-server-manuals/wsl-server-host-manual.html
```

Distribute only the client manual to users:

```text
~/wsl-server-manuals/wsl-server-client-manual.html
```

Distribute the project migration manual to project owners who will move a repository:

```text
~/wsl-server-manuals/wsl-server-project-migration-manual.html
```

Review the generated connection values before distribution. Dynamic LAN addresses remain placeholders by design and must be communicated from current Windows network state. Never add credentials or private keys to any generated manual.

## 8. Client configuration

Example client `~/.ssh/config`:

```sshconfig
Host my-wsl-server
    HostName WINDOWS_LAN_IP_OR_DNS
    Port 2222
    User WSL_USER
    IdentityFile ~/.ssh/id_ed25519_wsl_server
    IdentitiesOnly yes
```

Test non-interactively:

```bash
ssh -o BatchMode=yes -o IdentityAgent=none my-wsl-server 'printf WSL_SSH_OK'
```

For long-running work, use `tmux` inside WSL. SSH keepalives detect dead transports but do not preserve a shell after a network interruption.

## 9. Rollback

Disable LAN access but retain the startup task and state:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslSshLan.ps1" -Disable
```

Remove the Windows proxy, firewall rule, startup task, and state:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslSshLan.ps1" `
  -Distro Ubuntu -ListenPort 2222 -Remove
```

Disable the workbench inside WSL:

```bash
systemctl --user disable --now \
  wsl-server-workbench.service wsl-server-workbench-health.timer
```

Stopping LAN exposure does not require uninstalling OpenSSH or deleting keys. Keep rollback actions narrow.
