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
#
#  生成完会自检（verify_feed）：ipk 的 Filename 必须能在目录里找到、apk 的
#  每个包必须出现在 packages.adb 里，否则非零退出（CI 直接红）。
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 配置
# -----------------------------------------------------------------------------
KEY_RAW_URL="${KEY_RAW_URL:-https://github.com/MinimaxFlora/Extras_Paclages/raw/refs/heads/master/key}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"

# 支持 --dir 参数
if [ "${1:-}" = "--dir" ]; then
  REPO_DIR="$2"
  shift 2
fi
ARCHS=("$@")   # 空 = 全部架构目录

# 密钥目录默认跟着脚本走（脚本和 key/ 都在 master），可用 KEY_DIR 覆盖
KEY_DIR="${KEY_DIR:-$SCRIPT_DIR/key}"
KEY_PEM="$KEY_DIR/key-build.pem"          # EC 公钥（验证用，自动拉取）
KEY_PUB="$KEY_DIR/key-build.pub"          # usign 公钥（验证用，自动拉取）
KEY_BUILD="${KEY_BUILD:-$KEY_DIR/key-build}"               # usign 私钥（签名 ipk）
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
    "$HOME/.cache/imagebuilder"/openwrt-imagebuilder-* \
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

USIGN=$(resolve_tool usign)    || { echo "::error::缺少 usign 工具（tools/ 或 ImageBuilder）" >&2; exit 1; }
APK=$(resolve_tool apk)        || { echo "::error::缺少 apk 工具（tools/ 或 ImageBuilder）" >&2; exit 1; }
MKHASH=$(resolve_tool mkhash)  || { echo "::error::缺少 mkhash 工具（tools/ 或 ImageBuilder）" >&2; exit 1; }

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
if [ -s "$KEY_BUILD" ]; then HAVE_USIGN_KEY="yes"; fi
if [ -s "$KEY_BUILD_EC" ]; then HAVE_EC_KEY="yes"; fi
[ "$HAVE_USIGN_KEY" = yes ] || echo "::warning::缺少 usign 私钥 $KEY_BUILD → ipk 索引将不签名"
[ "$HAVE_EC_KEY" = yes ]   || echo "::warning::缺少 EC 私钥 $KEY_BUILD_EC → apk 索引将不签名"

# -----------------------------------------------------------------------------
# 索引生成
# -----------------------------------------------------------------------------
gen_ipk_index() {
  local dir="$1" n
  n=$(find "$dir" -maxdepth 1 -name '*.ipk' | wc -l)
  [ "$n" -gt 0 ] || { echo "  (无 ipk，跳过)"; return 0; }

  # 1) Packages
  #    在架构目录内以 "." 生成，再把相对前缀归一成裸文件名：
  #    opkg 拼 URL 的方式是 <src>/<Filename>，而客户端源已指向该架构目录，
  #    Filename 带 "x86_64/" 就会请求 .../x86_64/x86_64/xxx.ipk → 404。
  ( cd "$dir" && MKHASH="$MKHASH" bash "$IPKG_INDEX" . ) \
    | sed -E 's|^Filename: \.?/?|Filename: |' > "$dir/Packages"
  echo "  Packages: $(grep -c '^Package:' "$dir/Packages" || true) 个包"

  # 2) Packages.manifest（control 全文）
  : > "$dir/Packages.manifest"
  while IFS= read -r ipk; do
    tar -xzOf "$ipk" ./control.tar.gz 2>/dev/null | tar -xzOf - ./control 2>/dev/null \
      >> "$dir/Packages.manifest" || true
    echo "" >> "$dir/Packages.manifest"
  done < <(find "$dir" -maxdepth 1 -name '*.ipk' | sort)

  # 3) Packages.gz（-n 去掉时间戳，避免无意义的二进制 diff）
  gzip -9nc "$dir/Packages" > "$dir/Packages.gz"

  # 4) Packages.sig（usign）
  if [ "$HAVE_USIGN_KEY" = yes ]; then
    "$USIGN" -S -s "$KEY_BUILD" -m "$dir/Packages" -x "$dir/Packages.sig"
    if "$USIGN" -V -p "$KEY_PUB" -m "$dir/Packages" -x "$dir/Packages.sig" >/dev/null; then
      echo "  Packages.sig: usign 签名验证 OK"
    else
      echo "::error::Packages.sig 签名验证失败"
      return 1
    fi
  fi
  return 0
}

gen_apk_index() {
  local dir="$1" n
  n=$(find "$dir" -maxdepth 1 -name '*.apk' | wc -l)
  [ "$n" -gt 0 ] || { echo "  (无 apk，跳过)"; return 0; }

  # 1) packages.adb —— 不把输出塞进管道，退出码才不会被吞掉
  if [ "$HAVE_EC_KEY" = yes ]; then
    if ! ( cd "$dir" && "$APK" --sign-key "$KEY_BUILD_EC" mkndx --allow-untrusted \
             --pkgname-spec '${name}-${version}.apk' -o packages.adb ./*.apk ) > "$dir/.mkndx.log" 2>&1; then
      echo "::error::apk mkndx 失败（$dir）:"; sed 's/^/    /' "$dir/.mkndx.log"; rm -f "$dir/.mkndx.log"; return 1
    fi
    rm -f "$dir/.mkndx.log"
    if "$APK" verify --keys-dir "$KEY_DIR" "$dir/packages.adb" >/dev/null 2>&1; then
      echo "  packages.adb: EC 签名验证 OK ($n 包)"
    else
      echo "::error::packages.adb 签名验证失败"
      return 1
    fi
  else
    if ! ( cd "$dir" && "$APK" mkndx --allow-untrusted \
             --pkgname-spec '${name}-${version}.apk' -o packages.adb ./*.apk ) > "$dir/.mkndx.log" 2>&1; then
      echo "::error::apk mkndx 失败（$dir）:"; sed 's/^/    /' "$dir/.mkndx.log"; rm -f "$dir/.mkndx.log"; return 1
    fi
    rm -f "$dir/.mkndx.log"
    echo "  packages.adb: 未签名（没有 EC 私钥）"
  fi

  # 2) index.json（清单，给人和脚本看；architecture 用目录名而不是路径）
  local arch
  arch="$(basename "$dir")"
  "$APK" adbdump "$dir/packages.adb" 2>/dev/null | python3 -c '
import sys, json
arch = sys.argv[1]
pkgs, name = {}, None
for line in sys.stdin:
    s = line.strip()
    if s.startswith("- name:"):
        name = s.split(":", 1)[1].strip()
    elif s.startswith("version:") and name:
        pkgs[name] = s.split(":", 1)[1].strip()
        name = None
print(json.dumps({"version": 2, "architecture": arch, "packages": pkgs}, indent=2, ensure_ascii=False))
' "$arch" > "$dir/index.json"
  echo "  index.json: $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["packages"]))' "$dir/index.json") 个包"
  return 0
}

# -----------------------------------------------------------------------------
# 自检：索引里每条记录都要能在本地找到对应文件
# -----------------------------------------------------------------------------
verify_feed() {
  local dir="$1" bad=0 f base
  if [ -f "$dir/Packages" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -f "$dir/$f" ]; then
        echo "::error::$dir: Packages 里的 Filename 找不到文件: $f"
        bad=1
      fi
    done < <(awk -F': ' '/^Filename:/{print $2}' "$dir/Packages")
  fi

  if [ -f "$dir/packages.adb" ]; then
    "$APK" adbdump "$dir/packages.adb" 2>/dev/null \
      | awk '/^ *- name:/{n=$3} /^ *version:/{if(n!=""){print n"-"$2; n=""}}' > "$dir/.adb.pkgs" || true
    for f in "$dir"/*.apk; do
      [ -e "$f" ] || continue
      base="$(basename "$f" .apk)"
      if ! grep -qxF "$base" "$dir/.adb.pkgs"; then
        echo "::error::$dir: $f 没有出现在 packages.adb 里"
        bad=1
      fi
    done
    rm -f "$dir/.adb.pkgs"
  fi

  [ "$bad" -eq 0 ] && echo "  verify: 索引与文件一致 ✓"
  return "$bad"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
cd "$REPO_DIR" || { echo "::error::目录不存在: $REPO_DIR" >&2; exit 1; }

if [ "${#ARCHS[@]}" -gt 0 ]; then
  TARGETS=("${ARCHS[@]}")
else
  TARGETS=()
  for d in */; do
    d="${d%/}"
    case "$d" in key|tools|.git|.github|scripts) continue ;; esac
    if compgen -G "$d/*.ipk" >/dev/null || compgen -G "$d/*.apk" >/dev/null; then
      TARGETS+=("$d")
    fi
  done
fi

echo "================================================"
echo "  Extras_Paclages 索引生成"
echo "  仓库目录     : $REPO_DIR"
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
  verify_feed "$arch"
done

echo "================================================"
echo "  完成。新增/更新包后重新运行本脚本即可刷新索引。"
echo "================================================"
