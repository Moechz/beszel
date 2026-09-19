#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 Beszel（hub + agent）打包成
# TOS 7 应用中心规范的 deb 包（WebUI External Open / 新标签页模式）
#
# 规范依据: https://help.terra-master.com/developer/development-docs/
#   - Deb Development Specification（目录结构/config.ini/nginx/systemd/生命周期）
#   - Package Specification（版本号仅数字和点、三处一致、资产命名）
#
# 二进制来源（V6 红线：不得分发上游预编译二进制）:
#   BUILD_MODE=source（默认）— 从本仓库公开 CI 的源码构建 Release 拉取自建
#     二进制，SHA256SUMS 与 config.env pin 双层校验（坑 32/43 轻路线）
#   BUILD_MODE=compat — 直接用上游官方 Release 二进制，仅限本地快速验证，
#     产物 BUILD-INFO 带 NOT-FOR-SUBMISSION 标记，禁止提交商店
#
# 产物（out/）:
#   beszelmonitor_<版本>_<平台>.deb   完整版本名 deb（本地安装/测试用；
#     平台用 TOS 名 x86_64/aarch64——手动安装页拒收含 amd64/arm64 的文件名，坑 30a）
#   beszelmonitor_<platform>.deb      Release 资产名 deb（上架上传用，版本由 Release tag 表达）
#   beszelmonitor_<platform>.deb.sha256  上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
STAGE_DIR="$BUILD_DIR/pkgroot"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

# 完整版本 = 上游版本-打包迭代号（如 0.19.0-1；官方已不做硬性格式要求）
# 三处必须一致：config.ini / DEBIAN/control / .lang
VERSION_FULL="${BESZEL_VERSION}-${PKG_RELEASE}"

# ---------------- 目标平台（TOS / NAS 侧） ----------------
case "$TARGET_ARCH" in
  amd64)
    GOARCH="amd64"
    TOS_PLATFORM="x86_64"
    ELF_ARCH="x86-64"
    ;;
  arm64)
    GOARCH="arm64"
    TOS_PLATFORM="aarch64"
    ELF_ARCH="ARM aarch64"
    ;;
  *)
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

TAG="v$BESZEL_VERSION"
ARCH_UP=$(printf '%s' "$TARGET_ARCH" | tr '[:lower:]' '[:upper:]')

# --- compat 模式（上游预编译，仅本地测试） ---
RELEASE_BASE="https://github.com/henrygd/beszel/releases/download/$TAG"
# 注意：上游 tarball 资产名不带版本号（仅 deb 与 checksums 带），升级版本 URL 不变
HUB_TGZ="beszel_linux_${GOARCH}.tar.gz"
AGENT_TGZ="beszel-agent_linux_${GOARCH}.tar.gz"
CHECKSUMS="beszel_${BESZEL_VERSION}_checksums.txt"

# --- source 模式（本仓库公开 CI 源码构建产物） ---
HUB_BIN="beszel-linux-$GOARCH"
AGENT_BIN="beszel-agent-linux-$GOARCH"
BIN_SUMS="SHA256SUMS"
BIN_BUILDINFO="BUILD-INFO.txt"

LICENSE_FILE="LICENSE"
# 本地测试产物用 TOS 平台名（手动安装页拒收 amd64/arm64 文件名，坑 30a）
DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TOS_PLATFORM}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"       # Release 资产命名（无版本）

# 防 macOS 元数据混入（AppleDouble ._ / COPYFILE，坑 8）
export COPYFILE_DISABLE=1

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest-file>（多次重试 + 断点续传）
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then
    log "已缓存: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "下载: $(basename "$dest")"
  while [ $attempt -lt 8 ]; do
    attempt=$((attempt + 1))
    if curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
         --connect-timeout 30 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"  # 部分服务器不支持续传时从头再来
    warn "下载失败(第 $attempt 次): $(basename "$dest")，10 秒后重试..."
    sleep 10
  done
  die "下载失败: $url"
}

sha256_of() { # sha256_of <file> -> 64 位哈希（macOS/Linux 兼容）
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

normalize_text() { # 规范要求：文本文件 LF 行尾 + UTF-8 无 BOM（构建时统一清洗）
  python3 - "$@" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f:
        f.write(data)
PYEOF
}

# ============================================================
# 阶段: fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR"

  # 1. 二进制来源（V6：上架只允许 source 模式）
  local f want got want_pin
  if [ "$BUILD_MODE" = "source" ]; then
    fetch "$BIN_RELEASE_BASE/$HUB_BIN"    "$DL_DIR/$HUB_BIN"
    fetch "$BIN_RELEASE_BASE/$AGENT_BIN"  "$DL_DIR/$AGENT_BIN"
    fetch "$BIN_RELEASE_BASE/$BIN_SUMS"   "$DL_DIR/$BIN_SUMS"
    fetch "$BIN_RELEASE_BASE/$BIN_BUILDINFO" "$DL_DIR/$BIN_BUILDINFO" || true
    # 双层校验（坑 43）：Release 的 SHA256SUMS + config.env pin 相互独立互验
    for pair in "HUB:$HUB_BIN" "AGENT:$AGENT_BIN"; do
      kind=${pair%%:*}; f=${pair#*:}
      want=$(grep -a " $f\$" "$DL_DIR/$BIN_SUMS" | tail -1 | awk '{print $1}')
      [ -n "$want" ] || die "SHA256SUMS 中找不到 $f"
      eval "want_pin=\$${kind}_SHA256_${ARCH_UP}"
      [ -n "$want_pin" ] || die "config.env 缺 ${kind}_SHA256_${ARCH_UP}（先跑 CI build-v tag 并回填 pin）"
      got=$(sha256_of "$DL_DIR/$f")
      [ "$got" = "$want" ]     || die "sha256 与 SHA256SUMS 不符: $f（want=$want got=$got）"
      [ "$got" = "$want_pin" ] || die "sha256 与 config.env pin 不符: $f（want=$want_pin got=$got）"
      log "  ok: $f（双层校验通过）"
    done
  else
    warn "BUILD_MODE=compat：使用上游预编译二进制，产物仅限本地测试，禁止提交商店（V6）"
    fetch "$RELEASE_BASE/$HUB_TGZ"     "$DL_DIR/$HUB_TGZ"
    fetch "$RELEASE_BASE/$AGENT_TGZ"   "$DL_DIR/$AGENT_TGZ"
    fetch "$RELEASE_BASE/$CHECKSUMS"   "$DL_DIR/$CHECKSUMS"
    for f in "$HUB_TGZ" "$AGENT_TGZ"; do
      want=$(grep -a " $f\$" "$DL_DIR/$CHECKSUMS" | tail -1 | awk '{print $1}')
      [ -n "$want" ] || die "checksums 中找不到 $f"
      got=$(sha256_of "$DL_DIR/$f")
      [ "$got" = "$want" ] || die "sha256 不匹配: $f（want=$want got=$got，删除后重跑 fetch）"
      log "  ok: $f"
    done
  fi

  # 2. 上游 LICENSE（进 /usr/share/doc/beszelmonitor/copyright）
  fetch "https://raw.githubusercontent.com/henrygd/beszel/$TAG/LICENSE" "$DL_DIR/$LICENSE_FILE"
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树（官方规范布局）
# ============================================================
stage_stage() {
  if [ "$BUILD_MODE" = "source" ]; then
    [ -s "$DL_DIR/$HUB_BIN" ]   || die "缺少 $HUB_BIN，请先运行: ./build.sh fetch"
    [ -s "$DL_DIR/$AGENT_BIN" ] || die "缺少 $AGENT_BIN，请先运行: ./build.sh fetch"
  else
    [ -s "$DL_DIR/$HUB_TGZ" ]   || die "缺少 $HUB_TGZ，请先运行: ./build.sh fetch"
    [ -s "$DL_DIR/$AGENT_TGZ" ] || die "缺少 $AGENT_TGZ，请先运行: ./build.sh fetch"
  fi

  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "组装文件系统树: $STAGE_DIR（/usr/local/$APP_ID 规范布局）"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin"
  mkdir -p "$APP/images/icons"
  mkdir -p "$APP/nginx"
  mkdir -p "$APP/init.d"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # 二进制（规范要求放 bin/）
  if [ "$BUILD_MODE" = "source" ]; then
    log "  + bin/beszel + bin/beszel-agent（源码自建 $BESZEL_VERSION，BUILD_MODE=source）"
    install -m 0755 "$DL_DIR/$HUB_BIN"   "$APP/bin/beszel"
    install -m 0755 "$DL_DIR/$AGENT_BIN" "$APP/bin/beszel-agent"
  else
    log "  + bin/beszel + bin/beszel-agent（上游预编译 $BESZEL_VERSION，仅测试）"
    tar xzOf "$DL_DIR/$HUB_TGZ" beszel > "$APP/bin/beszel"
    chmod 0755 "$APP/bin/beszel"
    tar xzOf "$DL_DIR/$AGENT_TGZ" beszel-agent > "$APP/bin/beszel-agent"
    chmod 0755 "$APP/bin/beszel-agent"
  fi

  # config.ini（严格 JSON；@@...@@ 占位符渲染）
  log "  + config.ini（External Open: open_path=true, path=/$APP_ID/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # 多语言文件（文件名必须等于 app id；14 种必需语言）
  log "  + $APP_ID.lang（23 语言超集）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # 图标（透明背景 SVG，文件名必须等于 app id）
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # nginx 路由：app 目录内 nginx/ 满足 TOS 规范；同时以 dpkg 实体文件放
  # /etc/nginx/conf.d（metube 验证过的双落盘模式；postinst 负责校验与自愈）
  log "  + nginx/ + /etc/nginx/conf.d/（127.0.0.1:8090 回环反代）"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # systemd 服务：init.d/ 只放主服务（system_id 同名单元）——TOS 应用中心的安装
  # 流程按 init.d 迭代注册服务，多放辅助单元会导致其内部命令失败、
  # "App state will be deleted"、UI 卡"安装中"（真机实证，见坑 11）；
  # 辅助服务只以 dpkg 实体文件放 /etc/systemd/system（metube-pot 同款模式）
  log "  + init.d/（仅主服务）+ /etc/systemd/system/（hub + agent）"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/beszelmonitor.service"      "$APP/init.d/beszelmonitor.service"
  cp "$ASSETS_DIR/init.d/beszelmonitor.service"      "$STAGE_DIR/etc/systemd/system/beszelmonitor.service"
  cp "$ASSETS_DIR/init.d/beszelmonitor-agent.service" "$STAGE_DIR/etc/systemd/system/beszelmonitor-agent.service"

  # webui.bz2（WebUI 类应用必填；解压须含可打开的 .html。Beszel 面板内嵌于
  # hub 二进制、经 nginx 路由提供，此处为规范要求的占位前端）
  log "  + webui.bz2（占位前端，跳转 /$APP_ID/）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  for f in index.html app.js styles.css; do
    sed -e "s|@@VERSION@@|$VERSION_FULL|g" "$ASSETS_DIR/webui/$f" > "$WEBUI_DIR/$f"
  done
  # 坑 46：嵌套归档必须 uid/gid=0/uname=root/mtime=0 —— macOS bsdtar 无 --owner，
  # 统一用 python tarfile 重打（S11 警告的根治）
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYWEBUI'
import io, sys, tarfile
src, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, 'w:bz2') as tf:
    for name in ('index.html', 'app.js', 'styles.css'):
        with open(f'{src}/{name}', 'rb') as fh:
            data = fh.read()
        ti = tarfile.TarInfo(name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'
        ti.mtime = 0
        ti.mode = 0o644
        ti.type = tarfile.REGTYPE
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))
PYWEBUI

  # 隐私政策（坑 45：C3 必备资产；nginx 精确路由 /beszelmonitor/privacy-policy.html）
  log "  + privacy-policy.html（C3）"
  cp "$ASSETS_DIR/privacy-policy.html" "$APP/privacy-policy.html"

  # 构建溯源（V6 审计链：进包的 BUILD-INFO + 审核者用的 PROVENANCE.md）
  if [ "$BUILD_MODE" = "source" ] && [ -s "$DL_DIR/$BIN_BUILDINFO" ]; then
    cp "$DL_DIR/$BIN_BUILDINFO" "$APP/BUILD-INFO"
  else
    { echo "mode: compat (upstream prebuilt release binaries)"
      echo "upstream: henrygd/beszel $TAG"
      echo "*** NOT FOR STORE SUBMISSION — V6 rejects prebuilt-binary distribution ***"
    } > "$APP/BUILD-INFO"
  fi
  {
    echo "Beszel Monitor $VERSION_FULL — artifact provenance"
    echo "=================================================="
    echo "mode        : $BUILD_MODE"
    echo "upstream    : https://github.com/henrygd/beszel  tag $TAG  commit $SRC_COMMIT"
    echo "toolchain   : Go $GO_VERSION (public GitHub Actions runner)"
    if [ "$BUILD_MODE" = "source" ]; then
      echo "hub binary  : $BIN_RELEASE_BASE/$HUB_BIN"
      echo "              sha256 $(sha256_of "$DL_DIR/$HUB_BIN")"
      echo "agent binary: $BIN_RELEASE_BASE/$AGENT_BIN"
      echo "              sha256 $(sha256_of "$DL_DIR/$AGENT_BIN")"
      echo "audit trail : workflow .github/workflows/build.yml (public), build Release $BIN_RELEASE_BASE"
      echo "rebuild     : scripts/repro-build.sh in the packaging repository"
    else
      echo "hub binary  : $RELEASE_BASE/$HUB_TGZ (upstream prebuilt; testing only)"
      echo "agent binary: $RELEASE_BASE/$AGENT_TGZ (upstream prebuilt; testing only)"
      echo "*** compat build — NOT FOR SUBMISSION (V6) ***"
    fi
    echo "license     : MIT, full text in ./copyright"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/PROVENANCE.md"

  # 配置模板（以 .example 随包分发，postinst 首装复制为正式 env；升级不覆盖）
  log "  + *.env.example 配置模板"
  cp "$ASSETS_DIR/beszelmonitor.env"      "$APP/beszelmonitor.env.example"
  cp "$ASSETS_DIR/beszelmonitor-agent.env" "$APP/beszelmonitor-agent.env.example"

  # 文档
  cp "$DL_DIR/$LICENSE_FILE" "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * 基于 Beszel 上游 $BESZEL_VERSION 打包（hub + agent 双二进制）"
    if [ "$BUILD_MODE" = "source" ]; then
      echo "  * 二进制由公开 CI 从上游源码构建（双层 sha256 校验），零运行时依赖"
    else
      echo "  * 二进制取自上游官方 Release（sha256 校验；compat 测试包，禁止上架）"
    fi
    echo "  * WebUI External Open：新标签页经 /$APP_ID/ 路由访问，后端仅监听回环"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # 规范清洗：LF 行尾 + 去 BOM（所有 .ini/.lang/.conf/.service/env/.sh/.html/.js/.css）
  log "  清洗行尾（LF）与 BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" \
    "$APP/nginx/$APP_ID.conf" \
    "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/"*.service \
    "$STAGE_DIR/etc/systemd/system/"*.service \
    "$APP/"*.example \
    "$APP/privacy-policy.html" "$APP/BUILD-INFO" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/PROVENANCE.md"

  # 清理 macOS 扩展属性，避免污染 tar（AppleDouble / quarantine）
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  log "组装完成"
}

# ============================================================
# 阶段: verify —— 目标架构与规范关键项校验
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，请先运行: ./build.sh stage"
  local fail=0

  log "校验规范关键路径..."
  local p
  for p in "$APP/config.ini" "$APP/$APP_ID.lang" \
           "$APP/images/icons/$APP_ID.svg" \
           "$APP/nginx/$APP_ID.conf" \
           "$APP/init.d/beszelmonitor.service" \
           "$STAGE_DIR/etc/systemd/system/beszelmonitor.service" \
           "$STAGE_DIR/etc/systemd/system/beszelmonitor-agent.service" \
           "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
           "$APP/bin/beszel" "$APP/bin/beszel-agent" \
           "$APP/webui.bz2" \
           "$APP/beszelmonitor.env.example" \
           "$APP/beszelmonitor-agent.env.example" \
           "$APP/privacy-policy.html" \
           "$APP/BUILD-INFO" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/PROVENANCE.md"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  # V6：提交商店的包禁止 compat 模式（上游预编译二进制一票否决）
  if [ "$BUILD_MODE" = "source" ]; then
    grep -q "NOT FOR STORE SUBMISSION" "$APP/BUILD-INFO" && \
      { warn "BUILD-INFO 带 compat 标记，与 BUILD_MODE=source 矛盾"; fail=1; }
  else
    warn "BUILD_MODE=compat：本产物仅限本地测试，禁止提交商店（V6）"
  fi

  log "校验 config.ini（JSON 合法性 / 互斥字段 / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id = sys.argv[1:5]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
# WebUI External Open: open_path=true 且不得出现 type；path=/<id>/
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
if cfg.get("path") != f"/{app_id}/": errs.append(f"path 必须为 /{app_id}/")
if cfg.get("user") != "beszelmonitor": errs.append("user 应为 beszelmonitor")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（23 语言超集 + beta 门禁）..."
  local lang_missing
  lang_missing=$(python3 - "$APP/$APP_ID.lang" <<'PYEOF'
import sys
required = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es",
            "hu-hu","ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt",
            "ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl",
            "sv-se","th-th","vi-vn"]
text = open(sys.argv[1], encoding="utf-8").read()
missing = [t for t in required if f"[{t}]" not in text]
if __import__("re").search(r"\bbeta\b", text, 2):
    missing.append("含 beta 字样（V11 红线）")
print(",".join(missing))
PYEOF
)
  [ -z "$lang_missing" ] || { warn "lang 问题: $lang_missing"; fail=1; }

  # init.d 必须恰好一个服务文件（TOS 应用中心兼容性，真机实证）
  local n_initd
  n_initd=$(ls "$APP/init.d/"*.service 2>/dev/null | wc -l | tr -d ' ')
  [ "$n_initd" = "1" ] || { warn "init.d/ 必须只含主服务（当前 $n_initd 个）"; fail=1; }

  log "校验 systemd 服务（禁 Restart/必配 StartLimit/禁 ExecStart 变量展开）..."
  local svc
  for svc in "$APP/init.d/"*.service \
             "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（曾致全环境 502）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q '^User=beszelmonitor' "$svc" || { warn "必须 User=beszelmonitor: $svc"; fail=1; }
  done

  log "校验 webui.bz2（含 .html / 全部条目属主 root，坑 46）..."
  n_html=$(tar tjf "$APP/webui.bz2" | grep -c '\.html$' || true)
  [ "$n_html" -ge 1 ] || { warn "webui.bz2 缺少 html"; fail=1; }
  python3 - "$APP/webui.bz2" <<'PYWEBUI' || fail=1
import sys, tarfile
bad = [m.name for m in tarfile.open(sys.argv[1]).getmembers()
       if m.uid != 0 or m.gid != 0]
if bad:
    print(f"    webui.bz2 条目属主非 root: {bad}", file=sys.stderr)
    sys.exit(1)
PYWEBUI

  log "校验 ELF 架构（目标: $ELF_ARCH, for GNU/Linux）..."
  local f
  for f in "$APP/bin/beszel" "$APP/bin/beszel-agent"; do
    ftype=$(file "$f")
    if printf '%s' "$ftype" | grep -q "ELF.*$ELF_ARCH"; then
      log "  ok: $(basename "$f")"
    else
      warn "错误架构: ${f#$STAGE_DIR/} -> $ftype"
      fail=1
    fi
    # 静态链接 + 未加壳（UPX 壳会显示 "no section header"，坑 43）
    printf '%s' "$ftype" | grep -q "statically linked" || \
      { warn "应为静态链接: $(basename "$f") -> $ftype"; fail=1; }
    printf '%s' "$ftype" | grep -q "no section header" && \
      { warn "疑似加壳（no section header）: $(basename "$f")"; fail=1; }
  done

  log "检查 macOS Mach-O 混入（应为 0）..."
  local n_macho
  n_macho=$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "发现 $n_macho 个 Mach-O 文件！"; fail=1; }

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb —— 生成 .deb + 上架资产
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  # shellcheck source=makedeb.sh
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  # data.tar 内不得残留 macOS 元数据（AppleDouble ._ / .DS_Store，坑 8）
  local data_member n_meta
  data_member=$(ar t "$DEB_FILE" | grep -m1 '^data\.tar')
  n_meta=$(ar p "$DEB_FILE" "$data_member" | tar tf - | grep -c -E '(^|/)\._|(^|/)\.DS_Store' || true)
  [ "$n_meta" -eq 0 ] || die "data.tar 残留 $n_meta 个 macOS 元数据条目，请检查 stage 清洗"

  # Release 资产命名（版本由 Release tag 表达）+ 上架要求的 sha256
  cp "$DEB_FILE" "$STORE_DEB"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$STORE_DEB" | awk '{print $1"  "$2}' > "$STORE_DEB.sha256"
  else
    shasum -a 256 "$STORE_DEB" | awk '{print $1"  "$2}' > "$STORE_DEB.sha256"
  fi
  log "完成: $DEB_FILE"
  log "上架资产: $STORE_DEB (+ .sha256；Release tag 须为 v$VERSION_FULL)"
}

stage_info() {
  cat <<EOF
Beszel 版本    : $BESZEL_VERSION (完整版本 $VERSION_FULL)
构建模式      : $BUILD_MODE（source=公开 CI 源码自建 / compat=上游预编译仅测试）
目标架构      : $TARGET_ARCH (Go:$GOARCH TOS:$TOS_PLATFORM)
TOS app id    : $APP_ID（新标签页 /$APP_ID/，后端 127.0.0.1:8090）
产物          : $DEB_FILE
上架资产      : $STORE_DEB + .sha256（Release tag: v$VERSION_FULL）
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"
  log "已清理 stage（保留下载缓存）"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "已清理全部构建产物与下载缓存"
}

# ============================================================
# 入口
# ============================================================
STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "未知阶段: $STAGE（可用: fetch stage deb verify clean distclean info）" ;;
esac
