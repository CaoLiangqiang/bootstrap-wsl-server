# WSL Server Troubleshooting

## Contents

1. Diagnose by layer
2. Missing route or broken DNS
3. Windows port is unreachable
4. Password authentication fails
5. Public-key authentication fails
6. Workbench or self-check fails
7. Docker is unrelated

## 1. Diagnose by layer

Do not change multiple layers at once. Establish the first failing hop:

```text
WSL sshd:22
  <- Windows localhost forwarding
  <- Windows LAN listener and firewall
  <- Client routing and authentication
```

Test WSL first, then Windows, then the remote client.

## 2. Missing route or broken DNS

Symptoms include no `default via` route, `/etc/resolv.conf` pointing to a missing `/mnt/wsl/resolv.conf`, `Network is unreachable`, or hostname lookup failures.

Check:

```bash
ip route
readlink -f /etc/resolv.conf
cat /etc/resolv.conf
getent ahostsv4 example.com
```

If a newly enabled `.wslconfig` mirrored mode caused both the route and generated resolver to disappear, move that active configuration aside in Windows PowerShell and restart WSL:

```powershell
Move-Item "$env:USERPROFILE\.wslconfig" `
  "$env:USERPROFILE\.wslconfig.failed-mirrored-$(Get-Date -Format yyyyMMddHHmmss)"
wsl --shutdown
wsl -d Ubuntu
```

Do not hard-code a global resolver before proving the network route works. Preserve `/etc/wsl.conf` settings established by the base Skill for systemd, default user, and optional PATH isolation; they are independent from networking mode.

## 3. Windows port is unreachable

In elevated Windows PowerShell:

```powershell
Get-NetConnectionProfile
netsh interface portproxy show v4tov4
Get-NetTCPConnection -State Listen -LocalPort 2222
Get-Service iphlpsvc
Get-NetFirewallRule -DisplayName 'WSL SSH (LAN TCP 2222)' |
  Format-List Enabled,Action,Profile
Get-NetFirewallRule -DisplayName 'WSL SSH (LAN TCP 2222)' |
  Get-NetFirewallAddressFilter
```

The listener must exist, IP Helper must run, and the active Windows network must match the rule's Private profile. A Public profile will not match by design. Do not broaden the rule to `Any` merely to make a test pass.

Inside WSL:

```bash
systemctl is-active ssh.service
ss -ltn '( sport = :22 )'
```

## 4. Password authentication fails

Check the account and policy inside WSL:

```bash
passwd -S "$USER"
sudo sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers) '
sudo journalctl -u ssh -n 50 --no-pager
```

Set or change the password with `passwd` in the user's own terminal. Do not pass a password through the workbench, scripts, command arguments, or chat.

## 5. Public-key authentication fails

Server checks:

```bash
stat -c '%U:%G %a %n' "$HOME" "$HOME/.ssh" "$HOME/.ssh/authorized_keys"
ssh-keygen -lf "$HOME/.ssh/authorized_keys"
sudo sshd -T | grep -E '^(pubkeyauthentication|authorizedkeysfile|strictmodes|allowusers) '
sudo journalctl -u ssh -f
```

The public key must occupy its own complete line. Before appending, ensure an existing `authorized_keys` file ends with a newline; the bundled enrollment script does this automatically. A malformed older line should be preserved for review rather than guessed at or silently deleted.

Client checks:

```bash
ssh-keygen -y -f ~/.ssh/id_ed25519_wsl_server | ssh-keygen -lf -
ssh -vvv -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
  -i ~/.ssh/id_ed25519_wsl_server -p 2222 USER@WINDOWS_LAN_IP \
  'printf WSL_SSH_OK'
```

`Server accepts key` is only the unsigned offer stage. Authentication is complete only after the client signs, the server verifies, and the log reports `Accepted publickey` or the remote marker is returned.

If the server logs only `Connection closed ... [preauth]`, correlate the exact timestamp and temporarily raise server logging only with administrator approval. Restore normal logging afterward. First prove the server can complete an Ed25519 login locally with a temporary test key; revoke and delete that test key immediately.

Windows PowerShell 5.1 can mis-handle an empty `ssh-keygen -N ""` argument. Use stop-parsing or an interactive prompt when generating a key, then derive and compare its public fingerprint. Never share the private key.

## 6. Workbench or self-check fails

```bash
systemctl --user status wsl-server-workbench --no-pager
journalctl --user -u wsl-server-workbench -n 100 --no-pager
systemctl --user status wsl-server-workbench-health.timer --no-pager
curl -v http://127.0.0.1:4173/api/overview
ss -ltn '( sport = :4173 )'
```

The expected bind address is `127.0.0.1`, never `0.0.0.0`. Windows state collection requires explicit WSL interop via the absolute PowerShell path and a mounted Windows profile.

## 7. Docker is unrelated

Docker Engine can be active while Docker Hub is blocked or DNS-poisoned by a corporate network. Do not change WSL global DNS, enable mirrored networking, or widen the SSH firewall to fix a registry-specific failure. Diagnose Docker registry access separately and use a confirmed proxy or another network when required.
