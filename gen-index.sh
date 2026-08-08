#!/usr/bin/env bash
# =============================================================================
#  gen-index.sh — 为 Extras_Paclages 生成 ipk / apk 仓库签名索引
# -----------------------------------------------------------------------------
#  ipk 分支: Packages / Packages.gz / Packages.manifest / Packages.sig (usign)
#  apk 分支: packages.adb (EC P-256 签名) / index.json
#
#  用法:
#    ./gen-index.sh                       # 处理当前目录下所有架构子目录
#    ./gen-index.sh x86_64                # 只处理指定架构
#    ./gen-index.sh --dir /path/to/repo   # 指定仓库目录（默认脚本所在目录）
#
#  工具:
#    优先使用项目内 tools/ 目录（usign / apk / mkhash / ipkg-make-index.sh），
#    无需下载 ImageBuilder。若 tools/ 缺失，则回退到 ImageBuilder
#    （可用 IB_PATH 指定，否则自动搜索常见路径）。
#
#  密钥:
#    公钥自动从 GitHub 拉取（key/key-build.pem + key/key-build.pub）
#    私钥必须本地存在（用于签名）:
#      key/key-build         usign 私钥（Ed25519）→ 签 ipk
#      key/key-build.ec.key  EC P-256 私钥        → 签 apk
#    私钥路径可用环境变量覆盖: KEY_BUILD / KEY_BUILD_EC
# =============================================================================
set -uo pipefail

# -----------------------------------------------------------------------------
# 配置
# -----------------------------------------------------------------------------
KEY_RAW_URL="https://github.com/MinimaxFlora/Extras_Paclages/raw/refs/heads/master/key"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

# 支持 --dir 参数
if [ "${1:-}" = "--dir" ]; then
  REPO_DIR="$2"
  shift 2
fi
ARCHS=("$@")   # 空 = 全部架构目录

KEY_DIR="$REPO_DIR/key"
KEY_PEM="$KEY_DIR/key-build.pem"          # EC 公钥（验证用，自动拉取）
KEY_PUB="$KEY_DIR/key-build.pub"          # usign 公钥（验证用，自动拉取）
KEY_BUILD="${KEY_BUILD:-$KEY_DIR/key-build}"          # usign 私钥（签名 ipk）
KEY_BUILD_EC="${KEY_BUILD_EC:-$KEY_DIR/key-build.ec.key}"  # EC 私钥（签名 apk）

# -----------------------------------------------------------------------------
# 定位工具：优先项目内 tools/，回退 ImageBuilder
# -----------------------------------------------------------------------------
TOOLS_DIR="$SCRIPT_DIR/tools"
find_ib() {
  if [ -n "${IB_PATH:-}" ] && [ -d "$IB_PATH" ]; then
    echo "$IB_PATH"; return 0
  fi
  local d
  for d in \
    /tmp/fwtest/.imagebuilder/openwrt-imagebuilder-* \
    "$HOME/.imagebuilder"/openwrt-imagebuilder-* \
    /opt/openwrt-imagebuilder-*; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}

resolve_tool() {
  # $1 = 工具名（usign/apk/mkhash），优先 tools/，否则 ImageBuilder host bin
  if [ -x "$TOOLS_DIR/$1" ]; then
    echo "$TOOLS_DIR/$1"; return 0
  fi
  local IB
  IB=$(find_ib) || return 1
  if [ -x "$IB/staging_dir/host/bin/$1" ]; then
    echo "$IB/staging_dir/host/bin/$1"; return 0
  fi
  return 1
}

USIGN=$(resolve_tool usign) || { echo "::error::缺少 usign 工具（tools/ 或 ImageBuilder）" >&2; exit 1; }
APK=$(resolve_tool apk)   || { echo "::error::缺少 apk 工具（tools/ 或 ImageBuilder）" >&2; exit 1; }
MKHASH=$(resolve_tool mkhash) || { echo "::error::缺少 mkhash 工具（tools/ 或 ImageBuilder）" >&2; exit 1; }

IPKG_INDEX="$TOOLS_DIR/ipkg-make-index.sh"
if [ ! -f "$IPKG_INDEX" ]; then
  IB=$(find_ib) || { echo "::error::缺少 ipkg-make-index.sh（tools/ 或 ImageBuilder）" >&2; exit 1; }
  IPKG_INDEX="$IB/scripts/ipkg-make-index.sh"
fi

# -----------------------------------------------------------------------------
# 密钥准备：拉取公钥（验证用），检查私钥（签名用）
# -----------------------------------------------------------------------------
mkdir -p "$KEY_DIR"
for f in key-build.pem key-build.pub; do
  if [ ! -s "$KEY_DIR/$f" ]; then
    echo ">> 拉取公钥 $f ..."
    curl -fsSL -m 30 -o "$KEY_DIR/$f" "$KEY_RAW_URL/$f" || {
      echo "::warning::公钥 $f 下载失败（已存在则忽略）"
    }
  fi
done

HAVE_USIGN_KEY="no" HAVE_EC_KEY="no"
[ -s "$KEY_BUILD" ] && HAVE_USIGN_KEY="yes"
[ -s "$KEY_BUILD_EC" ] && HAVE_EC_KEY="yes"
[ "$HAVE_USIGN_KEY" = yes ] || echo "::warning::缺少 usign 私钥 $KEY_BUILD → ipk 索引将不签名"
[ "$HAVE_EC_KEY" = yes ]   || echo "::warning::缺少 EC 私钥 $KEY_BUILD_EC → apk 索引将不签名"

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
gen_ipk_index() {
  local dir="$1"
  local n
  n=$(find "$dir" -maxdepth 1 -name '*.ipk' | wc -l)
  [ "$n" -gt 0 ] || { echo "  (无 ipk，跳过)"; return; }

  # 1) Packages
  MKHASH="$MKHASH" bash "$IPKG_INDEX" "$dir" 2>/dev/null > "$dir/Packages"
  echo "  Packages: $(grep -c '^Package:' "$dir/Packages") 个包"

  # 2) Packages.manifest（control 全文）
  : > "$dir/Packages.manifest"
  for ipk in $(find "$dir" -maxdepth 1 -name '*.ipk' | sort); do
    tar -xzOf "$ipk" ./control.tar.gz 2>/dev/null | tar xzOf - ./control 2>/dev/null >> "$dir/Packages.manifest"
    echo "" >> "$dir/Packages.manifest"
  done

  # 3) Packages.gz
  gzip -9c "$dir/Packages" > "$dir/Packages.gz"

  # 4) Packages.sig（usign）
  if [ "$HAVE_USIGN_KEY" = yes ]; then
    "$USIGN" -S -s "$KEY_BUILD" -m "$dir/Packages" -x "$dir/Packages.sig"
    "$USIGN" -V -p "$KEY_PUB" -m "$dir/Packages" -x "$dir/Packages.sig" >/dev/null \
      && echo "  Packages.sig: usign 签名验证 OK" \
      || echo "::warning::Packages.sig 签名验证失败"
  fi
}

gen_apk_index() {
  local dir="$1"
  local n
  n=$(find "$dir" -maxdepth 1 -name '*.apk' | wc -l)
  [ "$n" -gt 0 ] || { echo "  (无 apk，跳过)"; return; }

  # 1) packages.adb（EC 签名）
  if [ "$HAVE_EC_KEY" = yes ]; then
    (cd "$dir" && "$APK" --sign-key "$KEY_BUILD_EC" mkndx --allow-untrusted \
      --pkgname-spec '${name}-${version}.apk' -o packages.adb *.apk 2>&1 \
      | grep -vE '^WARNING' | head -2)
    "$APK" verify --keys-dir "$KEY_DIR" "$dir/packages.adb" >/dev/null 2>&1 \
      && echo "  packages.adb: EC 签名验证 OK ($n 包)" \
      || echo "::warning::packages.adb 签名验证失败"
  else
    (cd "$dir" && "$APK" mkndx --allow-untrusted \
      --pkgname-spec '${name}-${version}.apk' -o packages.adb *.apk 2>&1 \
      | grep -vE '^WARNING' | head -2)
  fi

  # 2) index.json（从 adbdump 解析）
  "$APK" adbdump "$dir/packages.adb" 2>/dev/null | python3 -c "
import sys, json
arch = '$dir'
pkgs, name = {}, None
for line in sys.stdin:
    s = line.strip()
    if s.startswith('- name:'):
        name = s.split(':',1)[1].strip()
    elif s.startswith('version:') and name:
        pkgs[name] = s.split(':',1)[1].strip()
        name = None
out = {'version': 2, 'architecture': arch, 'packages': pkgs}
print(json.dumps(out, indent=2, ensure_ascii=False))
" > "$dir/index.json"
  echo "  index.json: $(python3 -c "import json;print(len(json.load(open('$dir/index.json'))['packages']))") 个包"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
cd "$REPO_DIR" || { echo "::error::目录不存在: $REPO_DIR" >&2; exit 1; }

# 确定要处理的架构目录
if [ "${#ARCHS[@]}" -gt 0 ]; then
  TARGETS=("${ARCHS[@]}")
else
  TARGETS=()
  for d in */; do
    d="${d%/}"
    case "$d" in key|tools|.git|scripts) continue ;; esac
    if ls "$d"/*.ipk >/dev/null 2>&1 || ls "$d"/*.apk >/dev/null 2>&1; then
      TARGETS+=("$d")
    fi
  done
fi

echo "================================================"
echo "  Extras_Paclages 索引生成"
echo "  工具来源     : $([ -x "$TOOLS_DIR/usign" ] && echo "项目内 tools/（无需 ImageBuilder）" || echo "ImageBuilder")"
echo "  usign        : $USIGN"
echo "  apk          : $APK"
echo "  处理架构     : ${TARGETS[*]:-（无）}"
echo "  usign 私钥   : $([ "$HAVE_USIGN_KEY" = yes ] && echo 有 || echo 无)"
echo "  EC 私钥      : $([ "$HAVE_EC_KEY" = yes ] && echo 有 || echo 无)"
echo "================================================"

for arch in "${TARGETS[@]}"; do
  echo "=== $arch ==="
  gen_ipk_index "$arch"
  gen_apk_index "$arch"
done

echo "================================================"
echo "  完成。新增/更新包后重新运行本脚本即可刷新索引。"
echo "================================================"
