# Windows WebUI 项目迁移到 WSL 服务器：端到端手册

本文供项目所有者和服务器管理员协作使用，目标是把一套原本在用户
Windows 电脑上运行的 WebUI 项目迁移到长期运行的 WSL2 Ubuntu 服务器，
并通过受认证的 HTTPS 地址交付给实际用户。

本文是迁移流程，不替代应用自身的安装说明。服务器必须先完成
`bootstrap-wsl-ai-dev` Phase 1 和本 Skill 的 SSH Phase 2；需要浏览器访问时，
还要按 `references/webui-apps.md` 启用 Phase 2b。

## 1. 完成标准

只有同时满足以下条件，迁移才算完成：

- 服务器上的代码能对应到一个明确的 Git 提交，且没有未解释的改动；
- 应用在 Linux 中完成构建、测试和真实业务流程验证；
- 应用由独立的 systemd 用户服务管理，异常退出后能自动恢复；
- 应用只监听 WSL 的 `127.0.0.1`，不直接暴露到局域网；
- 共享 Caddy 网关提供 HTTPS 和认证，Windows 只转发网关端口；
- 实际客户端已验证公共 CA 指纹、安装证书并完成浏览器验收；
- 密钥、令牌、密码、`.env` 和私有 CA 密钥均未进入 Git、聊天或日志；
- 必需的配置和持久数据已经进入加密备份，并做过恢复演练；
- 启动唤醒、运行期 watchdog、健康检查、回滚和责任人均有记录。

健康接口返回 `200` 只证明进程的一小部分可用，不能代替上述验收。

## 2. 角色、边界和交付物

### 项目所有者

项目所有者负责确认代码版本、许可证、构建方式、依赖、配置字段、数据库
迁移、持久数据、业务验收和应用级回滚。应用仓库继续拥有：

- 源代码、锁文件、迁移脚本和应用测试；
- 应用的 systemd 服务模板；
- `.env.example` 或配置字段说明，但不包含真实秘密；
- 健康接口、版本接口和应用运行手册。

### 服务器管理员

服务器管理员负责 SSH、公钥录入、WSL/systemd 基础、端口分配、共享 registry、
健康定时器、Caddy、Windows HTTPS 转发、公共 CA、watchdog 和备份平台。
管理员不应猜测应用的数据兼容性，也不应把应用秘密复制进本 Skill。

### 客户端验收人

客户端验收人负责在实际使用的电脑和浏览器上核对证书指纹、安装公共 CA、
验证登录和完整业务流程。服务器本机的 `curl` 成功不能替代这一步。

### 永久安全边界

- WSL 保持默认 NAT；不要为迁移启用 mirrored networking。
- SSH 仍由 Phase 2 管理。应用迁移不得重启 SSH、修改 SSH 端口或中断现有会话。
- 每个应用与 Caddy 都只监听 WSL `127.0.0.1`。
- 未认证工作台只允许服务器 Windows 本机访问 `127.0.0.1:4173`，不得转发到 LAN。
- 局域网只暴露共享的认证 HTTPS 网关；不要为每个应用新建裸 HTTP 转发。
- 私钥只留在创建它的受信设备上。服务器只接收 SSH 公钥。

## 3. 迁移记录和迁移前盘点

开始操作前建立一份不含秘密的迁移记录。至少填写：

| 项目 | 记录内容 |
|---|---|
| 应用 ID | 小写字母开头，只含小写字母、数字和连字符，最长 32 字符 |
| 显示名称 | 用户可识别的名称 |
| 源仓库与提交 | 仓库 URL、分支、完整 commit ID、tag（如有） |
| 代码责任人 | 姓名或团队及联系方式 |
| 传输方式 | clone、bundle、rsync 或 scp，以及选择理由 |
| Linux 运行目录 | 例如 `~/codebase/APP_ID`，不要放在 `/mnt/c` 下长期运行 |
| 服务单元 | 唯一的 `APP_ID.service` |
| 应用端口 | 未占用的高位端口，不能是保留的 `4173` |
| 健康路径 | 便宜、无副作用、不泄露秘密的 HTTP 路径 |
| 网关主机名 | 每个应用默认使用独立主机名，不使用 IP 地址 |
| 数据与报告 | 每个路径的所有者、规模、是否必需、停机一致性要求 |
| 外部依赖 | 数据库、代理、许可证、API、SMTP、网络共享等 |
| 恢复目标 | 可接受的数据丢失时间和恢复时间 |
| 验收人和窗口 | 客户端、日期、停机窗口和回退截止点 |

在原 Windows 电脑上盘点以下内容，不能仅凭“项目目录可以启动”来推断：

1. 记录 `git status`、当前分支、完整 commit ID、远端 URL 和 submodule/LFS 状态。
2. 列出未提交文件，并决定提交、排除还是作为数据单独迁移。
3. 查明真实启动命令、运行用户、工作目录、环境变量和所需端口。
4. 区分可重建内容与不可重建内容。虚拟环境、`node_modules`、缓存、构建目录
   通常可重建；数据库、上传文件、许可证和业务报告通常不可重建。
5. 记录语言和工具版本、锁文件、原生库、浏览器/驱动和外部命令依赖。
6. 查找 Windows 专属行为：盘符路径、反斜杠、`.bat`/PowerShell、COM、注册表、
   Office 自动化、Windows 服务、共享盘和仅有 Windows 版本的二进制文件。
7. 确认数据库写入一致性要求。迁移 SQLite 或文件数据库前必须停止写入或使用
   数据库支持的一致性导出方式，不能复制一个正在写入的文件。
8. 对要迁移的数据记录文件数、总大小和校验值；对代码记录 commit ID。

如果核心依赖只支持 Windows，不要伪装成已经完成 Linux 迁移。应先替换依赖、
把该组件留在受控的 Windows 服务中，或停止此次迁移并记录阻塞项。

## 4. 选择代码和文件传输方式

优先传递 Git 历史和可复现依赖，而不是复制整个开发目录。

| 方式 | 适用场景 | 保留 Git 历史 | 增量 | 注意事项 |
|---|---|---:|---:|---|
| `git clone` | 服务器能访问仓库，仓库状态完整 | 是 | 是 | 默认首选；服务器需要独立、最小权限的仓库认证 |
| `git bundle` | 服务器无法访问远端，或需离线交付 | 是 | 可再次生成增量 bundle | bundle 不包含未跟踪文件、LFS 对象和 submodule 内容 |
| `rsync` over SSH | 大量数据或多次增量同步 | 否（除非连 `.git`） | 是 | 最适合持久数据；先 dry-run，谨慎使用 `--delete` |
| `scp`/SFTP | 少量一次性文件、bundle 或导出包 | 取决于文件 | 否 | 简单但重传成本高；不要用它复制虚拟环境或秘密到共享目录 |

不要用云盘、聊天附件或公共临时链接传递私有仓库、`.env`、数据库或私钥。

### 4.1 直接 clone（首选）

服务器能访问源代码托管平台时，在**服务器 WSL 的 SSH 会话**中执行：

```bash
install -d -m 0755 ~/codebase
cd ~/codebase
git clone --recurse-submodules REPOSITORY_URL APP_ID
cd APP_ID
git switch EXPECTED_BRANCH
git rev-parse HEAD
git status --short
```

若使用 Git LFS，还要在服务器安装并初始化受支持的 Git LFS，然后执行
`git lfs pull` 和 `git lfs fsck`。输出的 commit ID 必须等于迁移记录中的版本。

私有仓库应优先使用服务器单独生成的 deploy key，并只把它的**公钥**登记到
代码托管平台；或者由管理员在服务器本地终端完成受批准的凭证登录。不要从
用户电脑复制 Git 私钥，也不要把 token 写入 clone URL、shell 历史或 service。

### 4.2 Git bundle（保留历史的离线交付）

先在**源 Windows 电脑的项目终端**中确保工作树状态已处理，然后执行：

```powershell
git status --short
git bundle create APP_ID.bundle --all
git bundle verify APP_ID.bundle
scp .\APP_ID.bundle SERVER_USER@SERVER_HOST:~/incoming/
```

再在**服务器 WSL**中执行：

```bash
git bundle verify ~/incoming/APP_ID.bundle
git clone ~/incoming/APP_ID.bundle ~/codebase/APP_ID
cd ~/codebase/APP_ID
git remote remove origin
git remote add origin REPOSITORY_URL
git rev-parse HEAD
git status --short
```

确认 clone、远端地址和所需提交都正确后，再删除传输用 bundle。Git bundle 不会
携带未跟踪文件；submodule 和 LFS 内容需要分别处理并校验。

### 4.3 rsync（数据或重复增量同步）

在装有 `rsync` 的客户端 WSL/Git 环境中先 dry-run：

```bash
rsync -aHvn --info=stats2 --exclude='.git/' --exclude='.venv/' \
  --exclude='node_modules/' --exclude='__pycache__/' \
  /mnt/DRIVE/PATH/PROJECT/ SERVER_USER@SERVER_HOST:~/incoming/APP_ID/
```

核对目标后去掉 `n` 执行正式同步。除非已经生成目标快照且明确需要镜像删除，
不要使用 `--delete`。运行数据应同步到权限受控的 staging 目录，校验后再原子
切换到最终位置；不要直接覆盖正在运行的数据库或上传目录。

### 4.4 scp/SFTP（少量文件）

使用 `scp` 传输 bundle、数据库一致性导出包或小型归档：

```powershell
scp .\EXPORT_FILE SERVER_USER@SERVER_HOST:~/incoming/
```

传输后在源端和服务器分别计算 SHA-256 并比对。若需迁移大量目录或多次重传，
改用 rsync。不要把整个 Windows Python 虚拟环境或 `node_modules` 复制到 Linux。

## 5. 凭证、配置和数据的安全迁移

先为每个敏感项确定所有者、目标路径、权限、轮换方式和备份要求。推荐边界：

- 仓库只包含 `.env.example`、字段说明和无秘密的默认值；
- 应用真实环境文件放在应用专属私有目录，权限 `600`，父目录权限 `700`；
- gateway 用户名和密码哈希位于 `~/.config/webui-gateway/gateway.env`；
- 应用 bootstrap 凭证只存受保护文件，并尽快转入批准的密码管理器；
- systemd `EnvironmentFile=` 只引用秘密文件路径，不把值写进 unit；
- registry 只记录服务、监听和健康信息，不能出现 token、密码或私钥。

真实秘密应由有权限的人通过受认证 SSH，在服务器本地交互式创建或从批准的
秘密系统恢复。不要把值放在命令参数、终端截图、问题单、聊天、URL 或 Git diff。

迁移旧 `.env` 前逐项审查：删除无用变量，替换 Windows 路径和主机名，轮换可能
暴露过的凭证，并确认生产值不会连接测试数据。写入后检查：

```bash
stat -c '%a %U:%G %n' PATH_TO_PRIVATE_DIR PATH_TO_ENV_FILE
git status --short
```

最终 `git status` 不得显示真实秘密。不要用 `source .env` 做通用检查，因为内容
可能被 shell 解释；由应用支持的配置加载器或结构化解析器验证。

对数据库和持久数据：

1. 先停止原系统写入或生成一致性快照/导出；
2. 记录导出时间、应用版本、schema 版本、大小和 SHA-256；
3. 传到服务器 staging 目录，保持最小权限；
4. 在副本上执行恢复和迁移脚本，不直接修改唯一原件；
5. 验证记录数、附件数量、关键查询和应用读取；
6. 保留原系统只读副本，直到回退截止点过后。

## 6. Linux 兼容适配

在应用尚未对 LAN 开放时完成适配。每一项都应有实际检查或测试：

- 将硬编码盘符和反斜杠改为配置项或跨平台路径 API；
- 文件名大小写必须与 import、模板和静态资源引用完全一致；
- shell 脚本使用 LF，并在 Git 中保留可执行位；不要依赖 `.bat` 或 PowerShell；
- 用 UTF-8 明确读写文本，不能依赖 Windows 默认代码页；
- 不依赖当前目录，路径应相对应用根或明确配置目录解析；
- 检查 Linux 文件权限、所有者、临时目录和原子重命名行为；
- 替换 Windows 专属二进制和原生扩展，锁定可用的 Linux 版本；
- 确认时区、区域、换行符和路径分隔符不会改变业务结果；
- 确认上传、下载、报告生成、子进程、出站代理和外部 API；
- 应用监听地址必须可配置为 `127.0.0.1`，不能是 `0.0.0.0`；
- 提供无副作用、低成本且不返回秘密的健康路径；最好另有版本路径。

长期运行目录应位于 WSL 的 Linux 文件系统，例如 `~/codebase/APP_ID`，避免使用
`/mnt/c`。这可以减少权限、大小写、文件通知和性能差异。

所有必要适配都应提交到应用仓库的迁移分支，由项目所有者评审并推送。不要在
服务器上长期保留无法重建的“手改版本”。若必须临时修补，记录 diff，并在上线
前回收到仓库提交。

## 7. 在 Linux 中重建依赖并验证

按仓库锁文件选择工具，不要在没有必要时改变包管理器或升级依赖。典型做法：

### Python

```bash
cd ~/codebase/APP_ID
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r REQUIREMENTS_LOCK_FILE
.venv/bin/python -m pytest
```

### Node.js

```bash
cd ~/codebase/APP_ID
npm ci
npm test
npm run build
```

使用项目指定的受支持版本和命令；上面只是形态示例。生产构建不得依赖源电脑
残留的全局包。若项目使用容器，Docker 的安装与网络策略仍由 Phase 1 管理；
镜像仓库不可达应单独诊断，不得为此改变 WSL 全局 DNS 或网络模式。

先以前台方式启动并只绑定回环，然后从服务器验证：

```bash
ss -ltn '( sport = :APP_PORT )'
curl --fail --max-time 5 http://127.0.0.1:APP_PORT/HEALTH_PATH
```

还要运行项目测试、数据迁移 dry-run、真实样例和关键业务流程。记录版本输出、
测试结果和所有已接受的警告。

## 8. 服务化

应用仓库应提供可审查的 systemd 用户服务模板。下面是最小参考，必须替换全部
占位符并按应用测试调整限制：

```ini
[Unit]
Description=DISPLAY_NAME
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=/home/SERVER_USER/codebase/APP_ID
EnvironmentFile=/home/SERVER_USER/.config/APP_ID/app.env
ExecStart=/home/SERVER_USER/codebase/APP_ID/PATH_TO_EXECUTABLE --host 127.0.0.1 --port APP_PORT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
MemoryHigh=MEMORY_HIGH
MemoryMax=MEMORY_MAX
TasksMax=256
LimitNOFILE=8192
NoNewPrivileges=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=default.target
```

不要在验证上传、报告、临时文件、浏览器下载和外部 API 前盲目增加
`ProtectHome`、`ProtectSystem`、`PrivateTmp` 或网络限制。服务命令不能包含秘密。

把 unit 安装到 `~/.config/systemd/user/APP_ID.service` 后：

```bash
systemctl --user daemon-reload
systemctl --user enable --now APP_ID.service
systemctl --user status APP_ID.service --no-pager
journalctl --user -u APP_ID.service -n 100 --no-pager
ss -ltn '( sport = :APP_PORT )'
curl --fail --max-time 5 http://127.0.0.1:APP_PORT/HEALTH_PATH
```

确认 `loginctl show-user SERVER_USER -p Linger` 满足无人登录时运行用户服务的要求。
修改服务后只重启该应用；不要重启 SSH 或整个 WSL。至少测试一次应用进程异常
退出后的自动恢复，并防止启动失败形成无限高速重试。

## 9. 注册健康检查和 HTTPS 网关

第一次安装 Phase 2b 时，先渲染审查：

```bash
bash scripts/install-webui-apps.sh \
  --app-id APP_ID \
  --app-name 'DISPLAY_NAME' \
  --service-unit APP_ID.service \
  --app-port APP_PORT \
  --health-path /HEALTH_PATH \
  --gateway-hostname APP_HOSTNAME \
  --gateway-port GATEWAY_LOOPBACK_PORT \
  --caddy-bin /ABSOLUTE/PATH/TO/CADDY \
  --render-only /tmp/APP_ID-webui-render
```

检查渲染结果中没有秘密、固定 LAN IP、无关用户名、未替换占位符或非回环监听。
第一次安装按 `references/webui-apps.md` 正式执行。若共享 operations tree 已存在，
安装脚本会拒绝覆盖；此时必须备份现状，通过 render-only 生成参考，只合并新应用
registry 条目和独立 Caddy site，不能替换其他应用配置。

每个新应用默认使用独立主机名。只有应用明确支持 base path 时才采用路径前缀。
Caddy 反向代理目标必须是 `127.0.0.1:APP_PORT`，网关本身也只能绑定 WSL 回环。

合并后先做结构和 Caddy 配置验证，再仅重启网关并启用该应用健康定时器：

```bash
~/wsl-server/apps/scripts/check-app-health.py --app APP_ID
systemctl --user enable --now wsl-app-health@APP_ID.timer
systemctl --user restart webui-gateway.service
systemctl --user status webui-gateway.service --no-pager
systemctl --user list-timers 'wsl-app-health@*' --no-pager
```

健康定时器默认负责检测和记录，不等同于应用自动修复；应用 service 的
`Restart=on-failure` 负责进程异常。不得把未认证的 workbench 注册成应用。

## 10. Windows 转发、证书和客户端访问

只有 WSL 网关已经健康后，管理员才能从提升权限的 Windows PowerShell 使用
`Configure-WslWebGatewayLan.ps1` 配置一个 HTTPS relay。先确认 Windows 网络是
Private，防火墙仅允许 `LocalSubnet` 或明确批准的单个客户端地址。脚本必须继续
保护 SSH 转发和其他不归它所有的规则。

网关使用 Caddy internal CA 时，只向客户端发放公共根证书。绝不能发放
`root.key`、`intermediate.key`、Caddy 数据目录或应用凭证。管理员在可信渠道
另行提供 SHA-256 指纹；客户端先核对指纹，再导入当前用户根证书存储：

```powershell
Import-Certificate -FilePath .\SERVER-webui-root.crt `
  -CertStoreLocation Cert:\CurrentUser\Root
```

为每个应用主机名配置受控 DNS；没有 DNS 时可暂时使用经管理员批准的客户端
hosts 条目。不能用 IP 替代证书中的主机名。关闭所有浏览器进程并重新打开后，
验证：

- 未提供认证的 HTTPS 请求返回 `401`；
- 正确认证后返回预期版本或健康响应；
- 浏览器证书链受信任，地址与证书主机名一致；
- 上传、下载、长任务、报告和用户实际业务流程全部工作。

直接 HTTP 转发绕过 TLS 和认证，只能作为明确标记的试点回退通道。实际客户端
完整验收和防火墙快照完成后，另行审批再移除它。

## 11. 启动唤醒和 12 分钟运行期 watchdog

Windows startup task 负责 Windows 开机后唤醒 WSL；runtime recovery watchdog
负责 WSL 后续空闲停止或异常退出后的恢复。二者不能代替应用自身的 systemd
restart 策略。

新增应用后，检查已部署的 `Configure-WslRecoveryWatchdog.ps1` 配置。需要让
watchdog 恢复该应用时，把 `APP_ID.service` 加入明确的 `UserServices` 列表，并
保留现有服务；监听检查只配置实际受管理的 Windows 入口。更新任务时使用脚本
的所有权和漂移检查，不要直接编辑任务内部 XML。

```powershell
& "$env:USERPROFILE\.wsl-server\Configure-WslRecoveryWatchdog.ps1" `
  -Distro DISTRO_NAME -IntervalMinutes 12 `
  -ListenPorts 'MANAGED_WINDOWS_PORTS' `
  -UserServices 'EXISTING_SERVICES,APP_ID.service'

& "$env:USERPROFILE\.wsl-server\Configure-WslRecoveryWatchdog.ps1" -Status
```

确认任务每 12 分钟重复、使用 S4U/Limited、`StartWhenAvailable` 已启用、最近结果
成功，并且没有重叠运行。不要运行 `wsl --shutdown` 来测试，因为它会中断用户。
在维护窗口用可恢复的应用故障测试服务重启；另行安排 Windows 冷启动验证。

workbench 服务和浏览器展示是两层：服务可被 systemd/watchdog 恢复，页面会定期
轮询数据；已断开的浏览器 TCP 会话不能被任务“保持”，服务恢复后浏览器需要
重新连接或刷新。workbench 仍只能在服务器 Windows 本机浏览器访问。

## 12. 加密备份和恢复演练

在正式切换前更新 Restic 源清单。至少包含：

- 应用 `.env`、许可证和其他不可重建配置；
- 数据库、上传文件、必须保留的报告和业务状态；
- `~/wsl-server` operations 配置和 registry；
- `~/.config/webui-gateway`；
- 完整 Caddy PKI，但只允许进入加密仓库。

排除 Git 仓库、虚拟环境、`node_modules`、缓存、构建目录和可重新下载的工具。
每个源必须标记 required 或 optional；required 源缺失时备份应失败，不能产生
“部分成功”。备份密码文件权限为 `600` 且位于 Git 外，其恢复方式记录在批准的
密码管理器中。

备份后执行：

```bash
restic snapshots
restic check
```

把选定快照恢复到全新的临时目录，核对配置权限、数据库可读性、关键文件数量
和校验值，不能直接覆盖生产目录。与服务器位于同一台 Windows 电脑或同一磁盘
的仓库只属于本地恢复，不是灾难恢复；重要系统还需要独立设备或远端加密副本。

## 13. 上线验收清单

### 代码和应用

- [ ] 服务器 commit ID 与批准版本一致，`git status --short` 无未解释输出。
- [ ] submodule、LFS、锁文件和 Linux 依赖完整。
- [ ] 单元、集成、数据迁移和真实业务样例通过。
- [ ] 环境文件权限正确，仓库和日志中没有秘密。
- [ ] 应用只监听 `127.0.0.1:APP_PORT`，健康路径快速且无副作用。
- [ ] systemd service 已启用，异常退出能恢复，日志没有持续错误。

### 平台和网络

- [ ] registry 校验通过，该应用的五分钟健康定时器已启用。
- [ ] Caddy 配置有效且只监听 WSL 回环。
- [ ] Windows 只暴露批准的 HTTPS 入口，防火墙限于 Private/批准范围。
- [ ] workbench `4173` 没有 portproxy 或 LAN 防火墙入口。
- [ ] SSH PID、监听、端口转发和当前连接未受迁移影响。
- [ ] startup task 和 12 分钟 watchdog 的主体、间隔、服务列表、最近结果正确。

### 客户端和恢复

- [ ] 实际客户端通过独立渠道核对公共 CA SHA-256 指纹。
- [ ] 未认证返回 `401`，认证后使用正确的 HTTPS 主机名访问。
- [ ] 实际浏览器完整工作流通过，而不仅是首页或健康接口。
- [ ] 必需配置和数据已进入最新加密快照，`restic check` 通过。
- [ ] 临时目录恢复演练通过，原 Windows 系统仍可按计划回退。

最后记录上线时间、应用 commit、数据库/schema 版本、备份 snapshot ID、Caddy
配置版本、客户端验收人和所有保留的临时回退入口。

## 14. 切换与回滚

切换前冻结原系统写入，创建最终一致性导出和加密快照，再把数据恢复到服务器。
完成服务器自测后才切换客户端主机名或入口。观察期内保留原系统只读，不要两端
同时接受写入，否则回滚时无法可靠合并数据。

如果验收失败，按所有权逆序回滚：

1. 停止客户端切换，并恢复原入口或原系统的只读/写入角色。
2. 禁用新应用的 health timer，并停止新应用 service；不要停止 SSH。
3. 从 Caddy 中移除或禁用该应用的独立 site，仅重启 gateway。
4. 从共享 registry 删除该应用条目，不得覆盖其他应用。
5. 只有在整个网关被退役时，才用受管 PowerShell 脚本移除其 Windows relay。
6. 仅在不再需要恢复任何应用时，才移除 runtime watchdog；否则只更新其服务列表。
7. 保留失败版本日志、数据库导出、秘密、Caddy PKI、Restic 快照和回滚证据，
   除非数据所有者另行授权销毁。

发生 registry、任务、端口代理或防火墙所有权漂移时应停止并核对，不得通过删除
宽泛规则、目录或任务来“恢复默认”。回滚完成后重新验证 SSH 和原服务可用。

## 15. 交接包

交接包不包含任何秘密，至少包括：

- 应用仓库 URL、批准 commit/tag、构建和测试命令；
- 应用 ID、服务名、回环端口、健康/版本路径和 HTTPS 主机名；
- 配置字段清单、秘密所有者和轮换方法，只写路径不写值；
- 数据目录、备份 required/optional 分类、保留策略和最近恢复演练记录；
- systemd、registry 和 Caddy 变更的已审查 diff；
- 客户端公共 CA 指纹、安装说明和证书到期/轮换责任人；
- startup/watchdog 状态、业务监控方式、日志位置和故障升级联系人；
- 上线验收记录、已知限制、回滚截止点和回滚步骤。

任何接手人员应能仅凭批准的仓库版本、交接包、加密备份和独立保管的凭证重建
应用。若仍依赖某位开发者电脑上的未提交文件或全局软件，迁移尚未完成。

## 16. 最终服务器检查

在**服务器 WSL**中运行：

```bash
systemctl --failed --no-pager
systemctl --user --failed --no-pager
systemctl --user status APP_ID.service --no-pager
systemctl --user status webui-gateway.service --no-pager
systemctl --user list-timers 'wsl-app-health@*' --no-pager
~/wsl-server/apps/scripts/check-app-health.py --app APP_ID
ss -ltnp
```

然后由管理员核对 Windows portproxy、防火墙、启动任务和 watchdog 的准确对象，
由客户端验收人完成真实浏览器流程。所有输出都应去除凭证后附到迁移记录中。
如果任何必需检查无法执行，应明确记录未验证项和原因，而不能将其写成通过。
