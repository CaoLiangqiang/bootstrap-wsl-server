# Optional WebUI Application Hosting (Phase 2b)

## Contents

1. Scope and ownership
2. Architecture and prerequisites
3. Prepare an application service
4. Render and install the operations baseline
5. Configure credentials and Caddy
6. Configure Windows HTTPS access
7. Install the client CA and verify the browser
8. Add the optional startup wake task
9. Add the optional runtime recovery watchdog
10. Back up secrets and persistent data
11. CAN E2E pilot pattern
12. Add later applications
13. Verification and rollback

## 1. Scope and ownership

Phase 2b is optional. Apply it only after the Phase 1 foundation and Phase 2
SSH server are healthy. It owns the shared application registry, read-only
health timers, authenticated HTTPS gateway, Windows HTTPS relay, public CA
bundle, and related operational documentation.

Each application repository continues to own its source, dependencies,
business service unit, environment files, migrations, reports, and application
tests. Do not copy application secrets into this Skill or the registry.

Long-running services use a separate application deployment root with
`releases/RELEASE_ID`, `shared`, and an atomic `current` symlink. Dependencies
and build output stay with each release; secrets, persistent data, logs, and
explicit runtime state stay under `shared`. Production units must start through
`current`, never through the mutable source checkout. Once a previous
known-good release exists, record its ID and path in the registry deployment
object so the rollback target is explicit.

Keep the live operational tree under `~/wsl-server/apps`. Keep reusable source
templates in this repository. Required systemd and Windows registrations may
point to the operational tree but must remain thin.

## 2. Architecture and prerequisites

Use one Windows LAN boundary:

```text
Client browser
  -> Windows HTTPS port 443
  -> Windows portproxy 0.0.0.0:443
  -> WSL 127.0.0.1:8443
  -> Caddy TLS and authentication
  -> application 127.0.0.1:APP_PORT
```

Preserve these boundaries:

- Keep default WSL NAT. Do not enable mirrored networking for WebUI access.
- Bind applications and Caddy only to `127.0.0.1` inside WSL.
- Keep the unauthenticated workbench on `127.0.0.1:4173`; never register or
  forward it.
- Do not change, reload, or restart SSH while installing Phase 2b.
- Keep Windows firewall rules on `Private` profiles and `LocalSubnet`, or one
  explicitly approved unicast IPv4 client address.
- Do not treat the registry as proof of Windows firewall, TLS, or
  authentication state. Verify those layers directly.

Require Python 3, `curl`, GNU coreutils, systemd user services, Caddy 2.6 or newer, a mounted Windows
profile for script deployment, and a WebUI application that can listen on
loopback. Obtain Caddy through an approved package source and verify the
package or binary; do not commit the binary to this repository.

## 3. Prepare an application service

Create and test the application-owned user service before exposing it. The
service must listen on a unique loopback port and provide a cheap HTTP health
endpoint. Apply resource limits appropriate to the application, for example:

```ini
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
MemoryHigh=768M
MemoryMax=1G
TasksMax=256
LimitNOFILE=8192
NoNewPrivileges=true
RestrictSUIDSGID=true
LockPersonality=true
```

Do not apply `ProtectHome`, `ProtectSystem`, `PrivateTmp`, address-family, or
network restrictions until application tests cover uploads, report output,
temporary files, browser downloads, and required outbound APIs.

Verify the unit and loopback endpoint:

```bash
systemctl --user status APP.service --no-pager
ss -ltn '( sport = :APP_PORT )'
curl --fail http://127.0.0.1:APP_PORT/HEALTH_PATH
```

## 4. Render and install the operations baseline

Review a rendered copy before changing the live server:

```bash
bash scripts/install-webui-apps.sh \
  --app-id APP_ID \
  --app-name 'DISPLAY NAME' \
  --service-unit APP.service \
  --app-port APP_PORT \
  --health-path /HEALTH_PATH \
  --gateway-hostname WINDOWS_HOSTNAME \
  --gateway-port 8443 \
  --caddy-bin /path/to/caddy \
  --source-path /home/SERVER_USER/codebase/APP_ID \
  --deploy-root /home/SERVER_USER/wsl-server/apps/APP_ID \
  --release-id VERSION-COMMIT \
  --source-commit FULL_GIT_COMMIT \
  --app-version VERSION \
  --render-only /tmp/webui-render
```

Inspect the rendered registry, Caddyfile, and units. Confirm that no secret
value, fixed LAN IP, unrelated username, unresolved placeholder, or
non-loopback listener is present. On a first installation with an absent target
directory, ensure its parent operations directory exists, then rerun without
`--render-only`:

```bash
install -d -m 0755 ~/wsl-server
```

The installer claims the application operations path atomically and refuses to
replace even an empty existing directory.

The installer is deliberately first-install only and refuses a non-empty
destination. It must not start, stop, restart, or enable the application,
gateway, timers, or SSH. If an operational registry already exists, use
`--render-only`, back up the live files, and merge only the new application
entry and explicit Caddy site instead of replacing unrelated entries.

After reviewing a first installation, create the private gateway environment
file and explicitly enable only the shared gateway and selected health timer:

```bash
systemctl --user enable --now webui-gateway.service
systemctl --user enable --now wsl-app-health@APP_ID.timer
```

Run the checker directly after registration:

```bash
~/wsl-server/apps/scripts/check-app-health.py --app APP_ID
```

The checker rejects non-loopback hosts and must not follow an HTTP redirect to
another origin.

## 5. Configure credentials and Caddy

Keep the private gateway directory at mode `700` and files at mode `600`:

```text
~/.config/webui-gateway/gateway.env
~/.config/webui-gateway/APP_ID.credentials
```

`gateway.env` contains the Caddy username and password hash. The application
credential file may contain a bootstrap username and plaintext password for
the administrator to move into an approved password manager. Never place the
plaintext password in a command argument, URL, Git diff, service log, or agent
message. Read it from a local terminal or protected file through authenticated
SSH.

Generate a bcrypt hash by sending the password over standard input:

```bash
caddy hash-password --algorithm bcrypt
```

Restart only `webui-gateway.service` after an atomic credential update. Verify
that the former credential returns `401` and the new credential returns `200`.

The baseline gateway routes one hostname root to one application. This is the
configuration validated by the CAN E2E pilot. Do not claim path-prefix support
for an application unless it explicitly supports that base path. For multiple
applications, prefer one hostname per application and arrange managed DNS or a
client hosts entry; then add an explicit Caddy site for each hostname.

## 6. Configure Windows HTTPS access

Copy the managed PowerShell relay script to the Windows profile:

```bash
install -d -m 0755 /mnt/c/Users/WINDOWS_USER/.wsl-server/apps
install -m 0644 scripts/Configure-WslWebGatewayLan.ps1 \
  /mnt/c/Users/WINDOWS_USER/.wsl-server/apps/Configure-WslWebGatewayLan.ps1
```

After Caddy is listening on WSL loopback, run the copied script from elevated
Windows PowerShell:

```powershell
& "$env:USERPROFILE\.wsl-server\apps\Configure-WslWebGatewayLan.ps1" `
  -ListenPort 443 -TargetPort 8443 -AllowedRemoteAddress LocalSubnet
```

The script owns only its exact portproxy entry, firewall rule, and state file.
It must fail closed on drift, port conflicts, incomplete state, or a non-Private
network profile. It must not remove SSH port `2222`, the workbench, unrelated
firewall rules, or an object it did not create.

## 7. Install the client CA and verify the browser

After Caddy creates its internal CA, distribute only the public root
certificate. Never distribute `root.key`, `intermediate.key`, the Caddy data
directory, or application credentials with the certificate bundle.

Record the SHA-256 fingerprint out of band:

```bash
openssl x509 -in CLIENT_ROOT.crt -noout -fingerprint -sha256
```

On the actual Windows client, verify the fingerprint and import the public
certificate for the current user:

```powershell
Import-Certificate -FilePath .\HOSTNAME-webui-root.crt `
  -CertStoreLocation Cert:\CurrentUser\Root
```

Close all browser processes, reopen the browser, and test the managed HTTPS
hostname. Acceptance requires all expected application workflows, not only a
health response. Verify separately that unauthenticated HTTPS returns `401`
and authenticated HTTPS returns the expected application version or health
response.

Keep an existing direct HTTP relay only as a labeled pilot rollback. It
bypasses gateway TLS and authentication. Remove it only with separate approval
after the real client browser test passes and a firewall snapshot exists.

## 8. Add the optional startup wake task

Copy the startup script into the Windows operations directory:

```bash
install -m 0644 scripts/Configure-WslStartupTask.ps1 \
  /mnt/c/Users/WINDOWS_USER/.wsl-server/Configure-WslStartupTask.ps1
```

Use the independent startup script from elevated Windows PowerShell:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslStartupTask.ps1" `
  -Distro Ubuntu
```

The task uses `AtStartup`, a short delay, `S4U`, `Limited`, and a `cmd.exe`
wrapper around `wsl.exe -d DISTRO --exec /bin/true`. It stores no password. A
small diagnostic log is overwritten on each run instead of growing forever.

Retain existing interactive-logon wake tasks until a maintenance-window test
proves that SSH and every enabled WebUI start after a Windows cold boot without
an interactive login. Do not run `wsl --shutdown` or reboot while users are
connected.

## 9. Add the optional runtime recovery watchdog

The startup task handles boot; the runtime watchdog handles a later idle or
unexpectedly stopped WSL instance. It is a Windows Scheduled Task that checks
the selected local listener ports every 12 minutes by default. If any check
fails, it runs `wsl.exe -d DISTRO --exec /bin/true` to wake systemd. It does
not run `wsl --shutdown`, restart SSH, modify portproxy, or expose the
unauthenticated workbench.

Copy and register it from an elevated Windows PowerShell session:

```bash
install -m 0644 scripts/Configure-WslRecoveryWatchdog.ps1 \
  /mnt/c/Users/WINDOWS_USER/.wsl-server/Configure-WslRecoveryWatchdog.ps1
```

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslRecoveryWatchdog.ps1" `
  -Distro Ubuntu -IntervalMinutes 12 -ListenPorts '2222,443,8080' `
  -UserServices 'can-e2e-verifier.service,webui-gateway.service,wsl-server-workbench.service'
```

The task uses passwordless S4U/Limited execution, starts when available, and
ignores overlapping runs. It owns only the task named `WSL DISTRO recovery
watchdog` and the adjacent `recovery-watchdog-state.json`; it refuses to
replace an unowned task or drifted managed state. Inspect it without elevation:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslRecoveryWatchdog.ps1" -Status
```

Remove only the managed task when it is no longer needed:

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslRecoveryWatchdog.ps1" -Remove
```

The watchdog wakes WSL and idempotently starts only the explicitly configured
systemd user services before checking the managed Windows listeners. Their
service units remain responsible for normal process restart behavior. The workbench page itself polls its API and
refreshes data about every 30 seconds; a browser that lost its TCP connection must
reconnect or reload after the service returns. The workbench remains local to
the Windows server host's browser at `http://127.0.0.1:4173` and must never be made reachable
through the LAN HTTPS relay without adding a separate authenticated design.

## 10. Back up secrets and persistent data

Use encrypted Restic snapshots for local recovery. Keep its password file at
mode `600` outside Git and keep an offline copy in an approved password
manager. At minimum include:

- application `.env` files and other non-rebuildable secrets;
- application persistent data and generated reports that must survive rebuild;
- `~/wsl-server` operational configuration;
- `~/.config/webui-gateway` credentials and hashes;
- the complete Caddy PKI directory, including private CA keys, only inside the
  encrypted repository.

Exclude Git repositories, virtual environments, caches, Node.js dependency
trees, rebuildable vendor directories, and copied Caddy binaries. Mark each source as
required or optional. Abort the backup when a required source is missing;
never silently produce a partial success.

A practical initial retention policy is 7 daily, 4 weekly, and 6 monthly
snapshots, followed by prune only after a successful backup. Run:

```bash
restic snapshots
restic check
```

Perform a restore into a new temporary directory and inspect it before
replacing live data. A repository on another drive in the same Windows
computer is a local recovery layer, not disaster recovery. Add a separate
managed device or remote repository for disaster recovery.

## 11. CAN E2E pilot pattern

The validated pilot used the CAN E2E requirements verifier as one application:

- application-owned user service with loopback-only HTTP;
- a cheap version endpoint for health checks;
- resource and restart limits in the repository-owned service template;
- one registry entry and five-minute read-only health timer;
- Caddy internal TLS and Basic authentication on loopback;
- one Windows HTTPS relay with `Private` and `LocalSubnet` scope;
- public CA installation on the actual Windows client;
- encrypted backup of `.env`, application state, reports, gateway credentials,
  Caddy PKI, and server operations;
- a direct unauthenticated HTTP relay retained temporarily for rollback.

Use the pilot as a sequence and acceptance model, not as a source of fixed
usernames, passwords, ports, hostnames, IP addresses, repository URLs,
certificate fingerprints, or data paths.

## 12. Add later applications

For each later project:

1. Clone or synchronize the application repository under the normal codebase.
2. Stage an immutable versioned release with release-local dependencies and
   shared config/data, then adapt and test its Linux service without LAN exposure.
3. Point every service command through `current`, bind it to an unused loopback
   port, and add a cheap health endpoint.
4. Register only paths to secrets and persistent data.
5. Enable one health timer instance and verify it.
6. Choose a dedicated hostname unless base-path support is proven.
7. Add and validate one explicit Caddy site.
8. Update backup required sources before calling the migration complete.
9. Test the full workflow from the actual client.

Do not add one Windows firewall and portproxy rule per application when the
shared authenticated gateway can own the LAN boundary.

## 13. Verification and rollback

Before completion, verify:

```bash
systemctl --failed --no-pager
systemctl --user --failed --no-pager
systemctl --user status webui-gateway.service --no-pager
systemctl --user list-timers 'wsl-app-health@*' --no-pager
~/wsl-server/apps/scripts/check-app-health.py --json
ss -ltnp
```

Also verify exact Windows portproxy and firewall filters, the startup task
principal and last result, recovery watchdog status and repetition interval,
public CA fingerprint, unauthenticated `401`,
authenticated `200`, current application version, Restic integrity, and a real
client browser workflow. Recheck the SSH PID, socket listeners, and connected
sessions to prove they were not interrupted.

Rollback in ownership order:

1. Remove the managed Windows HTTPS relay with the PowerShell script's
   `-Remove` mode.
2. Remove the managed runtime recovery watchdog with its `-Remove` mode if it
   is being retired.
3. Disable the gateway and application health timers without stopping SSH.
4. Remove only the selected registry entry and generated links.
5. Preserve credentials, Caddy PKI, Restic repository, snapshots, application
   data, and rollback exports unless the user separately authorizes purge.

Fail closed when state has drifted. Inspect and reconcile ownership instead of
deleting broad firewall rules, portproxy entries, systemd units, or directories.
