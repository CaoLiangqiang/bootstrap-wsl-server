# WSL Server Setup Runbook

## Contents

1. Target architecture
2. Prerequisites and inventory
3. Configure the WSL baseline
4. Configure OpenSSH
5. Configure Windows LAN forwarding
6. Verify password and public-key access
7. Generate the host and client manuals
8. Install the optional workbench
9. Acceptance checklist

## 1. Target architecture

Use this path for LAN access:

```text
Client computer
  -> Windows-LAN-IP:2222
  -> Windows portproxy 0.0.0.0:2222
  -> WSL localhost:22
  -> OpenSSH Server
```

Keep the workbench separate:

```text
Windows/WSL local browser -> 127.0.0.1:4173 only
```

The Windows host owns LAN exposure. WSL remains on default NAT, so a changing WSL address does not need to be embedded in the proxy rule.

## 2. Prerequisites and inventory

Run in Windows PowerShell:

```powershell
wsl --status
wsl --list --verbose
Get-NetConnectionProfile
Get-NetIPConfiguration | Where-Object IPv4DefaultGateway
netsh interface portproxy show all
```

Confirm:

- Windows 11 and WSL2 are current enough to support systemd.
- The intended distribution name is exact, commonly `Ubuntu`.
- The active LAN profile is `Private`. Do not silently change a managed corporate profile.
- The chosen port, default `2222`, is not already in use.
- `%USERPROFILE%\.wslconfig` does not force an unverified networking mode.

Run inside WSL from this Skill directory:

```bash
bash scripts/audit-wsl-server.sh
```

Resolve a missing default route or resolver before installing services.

## 3. Configure the WSL baseline

Run inside WSL, replacing `alice`:

```bash
sudo bash scripts/configure-wsl-base.sh --user alice
```

Add `--isolate-windows-path` only when the user wants WSL commands isolated from imported Windows PATH entries. This setting preserves explicit Windows interop and does not alter networking.

Then run in Windows PowerShell:

```powershell
wsl --shutdown
wsl -d Ubuntu
```

Back in WSL, verify:

```bash
ps -p 1 -o comm=
ip route
cat /etc/resolv.conf
```

Expected results are `systemd`, a `default via ...` route, and at least one resolver nameserver.

## 4. Configure OpenSSH

Run inside WSL:

```bash
sudo bash scripts/configure-wsl-sshd.sh --user alice --password-auth yes
passwd
bash scripts/verify-wsl-server.sh alice
```

The password is entered only into `passwd`. Never place it in a command argument, file, browser, chat, or agent prompt.

The managed policy enables public keys, optionally enables passwords, denies root, disables keyboard-interactive authentication, restricts logins to the chosen user, and sets connection keepalives.

## 5. Configure Windows LAN forwarding

Copy the Windows script from WSL, replacing the Windows profile name:

```bash
install -d -m 0755 /mnt/c/Users/WINDOWS_USER/.wsl-server
install -m 0644 scripts/Configure-WslSshLan.ps1 \
  /mnt/c/Users/WINDOWS_USER/.wsl-server/Configure-WslSshLan.ps1
```

Open an elevated Windows PowerShell and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& "$env:USERPROFILE\.wsl-server\Configure-WslSshLan.ps1" `
  -Distro "Ubuntu" -ListenPort 2222
```

The script:

- Enables the Windows IP Helper service.
- Adds `0.0.0.0:2222 -> 127.0.0.1:22` using `portproxy`.
- Creates an inbound TCP rule limited to `Private` and `LocalSubnet`.
- Creates a logon task that starts the selected WSL distribution.
- Stores only non-secret operational state under `%USERPROFILE%\.wsl-server`.

Verify in elevated Windows PowerShell:

```powershell
netsh interface portproxy show v4tov4
Get-NetTCPConnection -State Listen -LocalPort 2222
Get-NetFirewallRule -DisplayName 'WSL SSH (LAN TCP 2222)' |
  Format-List Enabled,Action,Profile
Get-NetFirewallRule -DisplayName 'WSL SSH (LAN TCP 2222)' |
  Get-NetFirewallAddressFilter
Get-ScheduledTask -TaskName 'Start WSL Ubuntu SSH at logon'
```

## 6. Verify password and public-key access

Find the current Windows LAN address in Windows PowerShell:

```powershell
Get-NetIPConfiguration |
  Where-Object IPv4DefaultGateway |
  Select-Object InterfaceAlias,@{n='IPv4';e={$_.IPv4Address.IPAddress}}
```

From the actual client computer, test password login:

```bash
ssh -p 2222 alice@WINDOWS_LAN_IP
```

Generate a client key on the client computer:

```bash
ssh-keygen -t ed25519 -a 64 -f ~/.ssh/id_ed25519_wsl_server
ssh-keygen -lf ~/.ssh/id_ed25519_wsl_server.pub
```

Transfer only the `.pub` file to the administrator. Enroll it inside WSL:

```bash
bash scripts/add-ssh-public-key.sh /path/to/client-key.pub
```

Return the fingerprint printed by the script. Test from the client:

```bash
ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
  -i ~/.ssh/id_ed25519_wsl_server -p 2222 alice@WINDOWS_LAN_IP \
  'printf WSL_SSH_OK'
```

Only `WSL_SSH_OK` or `Authenticated to ...` proves completed authentication.

## 7. Generate the host and client manuals

Run inside WSL after confirming the final hostname, users, distribution, and LAN SSH port:

```bash
bash scripts/render-manuals.sh \
  --wsl-user alice \
  --windows-user WINDOWS_USER \
  --windows-hostname WINDOWS_HOSTNAME \
  --distro Ubuntu \
  --ssh-port 2222
```

The default output directory is `~/wsl-server-manuals`:

```text
wsl-server-host-manual.html
wsl-server-client-manual.html
```

Keep the host manual with the administrator. Give the client manual to access users. Regenerate both after changing the hostname, WSL login user, distribution, or LAN SSH port. The generated files are standalone HTML and must not contain passwords, private keys, fixed LAN IPs, or unresolved `__PLACEHOLDER__` values.

## 8. Install the optional workbench

Install Ubuntu's Node.js package if `node` is absent. Then run inside WSL:

```bash
bash scripts/install-workbench.sh \
  --windows-user WINDOWS_USER \
  --distro Ubuntu \
  --ssh-port 2222
```

The installer also refreshes the two standalone manuals under `~/wsl-server-manuals`.

Open locally:

```text
http://127.0.0.1:4173
```

Verify:

```bash
systemctl --user status wsl-server-workbench --no-pager
systemctl --user status wsl-server-workbench-health.timer --no-pager
curl -fsS http://127.0.0.1:4173/api/overview
curl -fsS 'http://127.0.0.1:4173/api/health?limit=5'
```

## 9. Acceptance checklist

- Default NAT route and generated DNS are healthy after a full WSL restart.
- OpenSSH is active on WSL TCP 22.
- Root login is denied and only the selected WSL user is allowed.
- Windows listens on the selected port.
- The firewall is `Private` plus `LocalSubnet`, not `Any`.
- The scheduled task wakes the correct distribution.
- Password login succeeds if enabled.
- A signed public-key command returns the expected marker.
- Both standalone HTML manuals exist and contain the confirmed hostname, user, distribution, and port.
- The workbench, when installed, listens only on `127.0.0.1:4173`.
- The health timer records a current result.
