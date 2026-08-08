---
name: extras-paclages-repo
description: "Extras_Paclages 插件库：三分支结构、签名索引体系、gen-index.sh 用法与新增/更新插件包流程"
---

# Extras_Paclages 插件库维护

仓库: https://github.com/MinimaxFlora/Extras_Paclages
作用: OpenWrt 第三方插件库（类似 opkg.cooluc.com 的带签名索引插件源），
由 gh-action-imagebuilder 构建固件时按版本自动拉取（24.x→ipk 分支，25.x→apk 分支）。

## 仓库结构（三分支）

### master 分支（维护工具，不存包）
- `gen-index.sh` — 索引生成脚本（核心）
- `tools/` — 内置二进制：usign / apk / mkhash / ipkg-make-index.sh（无需 ImageBuilder）
- `key/` — 公钥：key-build.pem（EC P-256 公钥）、key-build.pub（usign Ed25519 公钥，指纹 ed1aabca0184085f）
- **私钥不入库**：/tmp/keys/ 本地保留 key-build（usign 私钥）、key-build.ec.key（EC 私钥）

### ipk 分支（OpenWrt 24.x）
- 3 架构目录：aarch64_cortex-a53 / aarch64_generic / x86_64
- 每目录：*.ipk 包 + Packages / Packages.gz / Packages.manifest / Packages.sig（usign 签名）

### apk 分支（OpenWrt 25.x）
- 3 架构目录同上
- 每目录：*.apk 包 + packages.adb（EC P-256 签名）+ index.json

## 签名密钥体系（对齐 OpenWrt 官方）
- ipk 用 usign (Ed25519)：key-build.pub（RWR... 开头，untrusted comment: Local build key）
- apk 用 EC P-256：key-build.pem
- 固件里预置公钥：24.x → /etc/opkg/keys/key-build.pub；25.x → /etc/apk/keys/key-build.pem

## gen-index.sh 用法
```
./gen-index.sh                       # 处理当前目录所有架构子目录
./gen-index.sh x86_64                # 只处理指定架构
./gen-index.sh --dir /path/to/repo   # 指定仓库目录
```
- 密钥：公钥自动从 GitHub master 拉取；私钥必须本地存在
  （key/key-build + key/key-build.ec.key，可用环境变量 KEY_BUILD / KEY_BUILD_EC 覆盖）
- 工具优先用项目内 tools/，缺失才回退 ImageBuilder（IB_PATH 可指定）

## 新增/更新插件包流程（经验总结）

1. 下载包到 /tmp/pkg-update/：
   - 分架构包：下载各架构 tar.gz，解压取 .ipk/.apk
   - 不分架构包（如 openclash _all.ipk / .apk）：复制到**所有 3 个架构目录**
2. 处理分支：
   ```
   cd /tmp/ep-repo
   git checkout ipk
   # 删旧版: git rm 旧包名；cp 新包到 3 个架构目录
   git add -A && git commit -m "packages: ..."  # 身份 MinimaxFlora <zj18139624826@gmail.com>
   # 提交后（必须先提交才能切分支）再 checkout apk 重复同样操作
   ```
3. 重新生成索引：
   ```
   cp <master 的 gen-index.sh> 到仓库根（ipk/apk 分支没有此文件）
   mkdir -p key && cp /tmp/keys/*.pem /tmp/keys/*.pub /tmp/keys/key-build /tmp/keys/key-build.ec.key key/
   # ⚠️ 先清理仓库里杂目录（run-unpack-test/verify-ipk 等测试残留会被当架构扫进去！）
   bash gen-index.sh --dir /tmp/ep-repo
   rm -rf key gen-index.sh   # 提交时排除（只属于 master）
   git add -A && git commit -m "repo: regenerate ... index" && push
   ```
4. 推送两个分支：`git push origin ipk apk`
5. 验证：`git ls-tree -r --name-only origin/ipk | grep 包名` + 确认 Packages.sig/packages.adb 签名验证 OK

## 注意
- 索引必须重新生成，否则 opkg/apk 装不上新包
- 私钥永不入库；公钥只放 master/key/
- 验证结果应显示 "usign 签名验证 OK" / "EC 签名验证 OK"
- 当前状态参考：ipk=126 包、apk=127 包（含 openclash 0.47.133 + airconnect 1.11.2，2026-08-09）
