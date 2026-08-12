# Phase 1 Foundation Integration

Use `bootstrap-wsl-ai-dev` first when the computer is also an AI development workstation. The server Skill is an extension and must consume the foundation's outputs instead of recreating them.

## Required handoff checks

Run the base Skill's audit and validation, then confirm inside WSL:

```bash
ps -p 1 -o comm=
id -un
ip -4 route show default
grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf
```

Expected: `systemd`, the selected WSL user, a default route, and a generated resolver. If `[interop] appendWindowsPath=false` is selected, retain it; explicit absolute Windows paths used by the server workbench remain valid.

## Ownership

The base Skill owns native tool installation, PATH isolation, Git/AI client configuration, Docker and its proxy decisions, Windows AI cleanup, Explorer registry integration, and network diagnostics. The server Skill owns only OpenSSH server policy, `authorized_keys`, Windows SSH `portproxy`, the Private/LocalSubnet firewall rule, the WSL startup task, the loopback workbench, health checks, and the host, client, and project migration HTML manuals.

Neither phase should rewrite `.wslconfig`, mirrored networking, global WSL DNS, or unrelated `/etc/wsl.conf` sections during the server handoff. Keep WSL on default NAT.

## Shared file contract

| File or state | Base phase | Server extension |
|---|---|---|
| `/etc/wsl.conf` `[interop]` | Configure if selected | Read and preserve |
| `/etc/wsl.conf` `[boot]`, `[user]` | Configure with `configure-wsl-systemd.sh` | Verify; fallback only if base unavailable |
| `/etc/wsl.conf` network sections and `.wslconfig` | Diagnose only with explicit network request | Never modify |
| `~/.ssh/config` and client keys | Manage Git/AI client access | Read only |
| `~/.ssh/authorized_keys` and `sshd_config.d/99-wsl-server.conf` | Do not manage | Manage server access |
| Docker service, images, and daemon proxy | Manage when selected | Observe only |

## Handoff command

After the base validation passes, invoke:

```text
Use $bootstrap-wsl-server to add the LAN SSH server extension and generate the host, client, and project migration manuals.
```
