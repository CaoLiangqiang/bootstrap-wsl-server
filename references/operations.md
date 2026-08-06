# WSL Server Operations

## Contents

1. Daily status
2. Access records
3. Public-key enrollment
4. Password and port management
5. Workbench and health history
6. Manual regeneration and delivery
7. Client configuration
8. Rollback

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

Accept only an OpenSSH `.pub` file:

```bash
bash scripts/add-ssh-public-key.sh /path/to/user.pub
ssh-keygen -lf ~/.ssh/authorized_keys
stat -c '%U:%G %a %n' ~/.ssh ~/.ssh/authorized_keys
```

Expected modes are `700` for `.ssh` and `600` for `authorized_keys`. Return the full SHA256 fingerprint to the user. Never accept a private key.

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

## 6. Manual regeneration and delivery

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

Review the generated connection values before distribution. Dynamic LAN addresses remain placeholders by design and must be communicated from current Windows network state.

## 7. Client configuration

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

## 8. Rollback

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
