#!/usr/bin/env bash
# ============================================================
# repro-build.sh — 审核者复核用的 beszel 源码构建配方
#
# 与 .github/workflows/build.yml 的 source-build job 同参数：
#   - 上游 tag 归档（git clone --branch <tag>，锁 commit）
#   - Go 工具链版本锁定（config.env GO_VERSION）
#   - CGO_ENABLED=0（纯 Go，无交叉链依赖）
#   - 构建参数与上游 .goreleaser.yml 一致（hub 无 ldflags；
#     agent -ldflags "-s -w"；上游对 arm32 额外注入 buildGOARM，TOS 仅需
#     amd64/arm64，该变量为空，等价于不注入）
#   - 不使用 UPX（上游对部分产物加壳，我们明确不加：壳会显示
#     "no section header"，观感即否决，见 TOS-DEB-PACKAGING-GUIDE 坑 43）
#
# 产物哈希依赖工具链版本与构建环境；本仓库 build-v* Release 的
# SHA256SUMS 为 canonical。本配方用于验证"源码 → 二进制"路径真实可走，
# 在同版本工具链 + 相同 runner 镜像下可得到位级一致产物。
# ============================================================
set -euo pipefail

: "${TAG:=v0.19.0}"
: "${COMMIT:=ffcdb041670a501611727848649d28d886beb231}"
: "${GO_VER:=1.27.1}"

die() { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

command -v go >/dev/null 2>&1 || die "需要 Go ${GO_VER}（https://go.dev/dl/）"
have_go=$(go env GOVERSION)
if [ "$have_go" != "go${GO_VER}" ]; then
  echo "警告: 本机工具链 ${have_go} 与 CI pin go${GO_VER} 不一致，产物哈希会不同（功能等价）" >&2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone --depth 1 --branch "$TAG" https://github.com/henrygd/beszel.git "$work/src"
cd "$work/src"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || die "上游 tag 的 commit 与 pin 不一致（$(git rev-parse HEAD) != $COMMIT）"

# 上游 .goreleaser.yml before-hook 等价步骤：
# go mod tidy —— 对已冻结的 tag 归档是幂等操作，CI/本配方均跳过（不改依赖）
go generate -run fetchsmartctl ./agent   # 按仓库内 pinned sha 拉取 agent 的 smartctl 负载

mkdir -p "$work/out"
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch \
    go build -o "$work/out/beszel-linux-$arch" ./internal/cmd/hub
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch \
    go build -ldflags "-s -w" -o "$work/out/beszel-agent-linux-$arch" ./internal/cmd/agent
done

echo "== 构建产物 =="
file "$work/out"/*
( cd "$work/out" && sha256sum beszel-linux-* beszel-agent-linux-* )
echo ""
echo "对照 canonical 哈希: https://github.com/Moechz/beszel/releases（build-v* Release 的 SHA256SUMS）"
echo "产物目录: $work/out（脚本退出时自动清理，需要保留请先拷出）"
