# VERIFICATION.md — Beszel Monitor (TOS) 构建来源与复核指南

本文件面向 TerraMaster 应用中心审核者，说明 `beszelmonitor` deb 包内每个
外来产物的来源、锁定方式与复核路径。**本包不分发任何上游预编译二进制**
（V6）：deb 内的 `beszel` / `beszel-agent` 由本仓库公开 GitHub Actions 从
上游源码构建。

## 1. 产物来源表

| 产物 | 来源 | 锁定 |
|---|---|---|
| `/usr/local/beszelmonitor/bin/beszel` | 本仓库 CI 从上游源码构建 | Release `SHA256SUMS` + `config.env` pin 双层 sha256（见 §3） |
| `/usr/local/beszelmonitor/bin/beszel-agent` | 同上 | 同上 |
| `LICENSE`（→ copyright） | 上游 tag 归档 | tag/commit 锁定 |
| 其余文件（config.ini、lang、nginx conf、systemd units、生命周期脚本、图标、webui 占位页、隐私政策） | 本仓库源码 | git 历史 |

上游源码锁定：

- 上游：`henrygd/beszel` tag `v0.19.0`
- commit：`ffcdb041670a501611727848649d28d886beb231`
- 工具链：Go `1.27.1`（`config.env: GO_VERSION`，workflow `setup-go` 同源）

## 2. 构建配方（与上游 CI 参数一致）

源码构建 job（`.github/workflows/build.yml` → `source-build`，由
`build-v*` tag 触发）执行：

```bash
git clone --depth 1 --branch v0.19.0 https://github.com/henrygd/beszel.git
# commit 与 config.env SRC_COMMIT 比对，不一致即失败
go generate -run fetchsmartctl ./agent   # 上游 .goreleaser.yml before-hook
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o beszel-linux-amd64       ./internal/cmd/hub
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o beszel-agent-linux-amd64 ./internal/cmd/agent
# arm64 同参数
```

与上游 `.goreleaser.yml` 的对照与已知偏差：

| 项 | 上游 | 本构建 | 说明 |
|---|---|---|---|
| CGO | `CGO_ENABLED=0` | 同 | 纯 Go（PocketBase 用 modernc SQLite），静态链接 |
| hub ldflags | （无） | 同 | 上游 hub 构建即无 ldflags |
| agent ldflags | `-s -w -X …buildGOARM={{.Arm}}` | `-s -w` | `{{.Arm}}` 仅 arm32 有值；amd64/arm64 为空，等价 |
| UPX | 上游不对其发布产物加壳 | 不使用 | 明确排除加壳（`file` 显示完整 section header） |
| `go mod tidy` | before-hook | 跳过 | 对冻结 tag 幂等，跳过以不改依赖 |
| go generate（smartctl） | before-hook | 同指令 | 按仓库内 `go:generate` 的 pinned sha 拉取 agent 的 smartctl 负载（Windows agent 资产，Linux 构建不使用） |

审核链三链接（提审表单同填）：

1. workflow 文件：https://github.com/Moechz/beszel/blob/main/.github/workflows/build.yml
2. 公开 Actions runs：https://github.com/Moechz/beszel/actions
3. 源码构建 Release（含 SHA256SUMS / BUILD-INFO.txt）：https://github.com/Moechz/beszel/releases/tag/build-v0.19.0

## 3. 哈希校验（两层独立互验）

deb 打包时（`build.sh` fetch，BUILD_MODE=source）对每个二进制做两道校验：

1. 与源码构建 Release 的 `SHA256SUMS` 比对；
2. 与 `config.env` 内 `HUB_SHA256_*` / `AGENT_SHA256_*` pin 比对
   （pin 从 Release 的 SHA256SUMS 回填，双通道防单点篡改）。

包内留档：`/usr/local/beszelmonitor/BUILD-INFO`（CI 产出的构建信息）与
`/usr/share/doc/beszelmonitor/PROVENANCE.md`（完整来源表 + 哈希）。

## 4. 复核路径

- **重放配方**：`scripts/repro-build.sh`（本仓库）——任何 Linux 机器上按
  同参数从上游源码重建，工具链版本一致时产物位级一致。
- **抽查进包哈希**：解包 deb 后
  `sha256sum usr/local/beszelmonitor/bin/beszel` 对照 SHA256SUMS / PROVENANCE.md。

## 5. 运行时行为要点（审核相关）

- 后端仅监听 `127.0.0.1:8090`，无对外端口；WebUI 经 TOS nginx 反代
  `/beszelmonitor/` 以新标签页打开（`open_path:true`，无 `type` 字段）。
- systemd 单元无 `Restart=`（S05），`ExecStart` 全部写死参数（无变量展开）。
- 隐私政策随包（`/usr/local/beszelmonitor/privacy-policy.html`）并以 nginx
  精确路由 `location = /beszelmonitor/privacy-policy.html` 提供（C3/C 系）。
- 生命周期脚本不联网安装任何东西（S8）；agent 令牌等凭据只落
  root 0600/0640 文件，不进日志（F10）。
