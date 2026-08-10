---
name: extras-paclages-repo
description: "Extras_Paclages 插件库：三分支结构、签名索引体系、sync-packages 工作流、gen-index.sh 用法与新增/更新插件包流程"
---

# Extras_Paclages 插件库维护

仓库: https://github.com/MinimaxFlora/Extras_Paclages
作用: OpenWrt 第三方插件库（带签名索引的插件源），
由 gh-action-imagebuilder 构建固件时按版本自动拉取（24.x→ipk 分支，25.x→apk 分支），
也可作为独立 opkg / apk 软件源使用。

## 仓库结构（三分支）

### master 分支（维护工具，不存包）
- `gen-index.sh` — 索引生成脚本（核心，支持 `--dir` 与 `KEY_DIR` 环境变量）
- `tools/` — 内置二进制：usign / apk / mkhash / ipkg-make-index.sh（无需 ImageBuilder）
- `key/` — 公钥：key-build.pem（EC P-256 公钥）、key-build.pub（usign Ed25519 公钥，指纹 e1a9369072ae3a0d）
- `.github/workflows/sync-packages.yml` — 自动同步 openwrt_package release → ipk/apk 分支
- `.github/scripts/sync_packages.py` — 同步+按插件名去重脚本
- **私钥不入库**：存放在 GitHub Actions secrets（KEY_BUILD / KEY_BUILD_EC）

### ipk 分支（OpenWrt 24.x）
- 3 架构目录：aarch64_cortex-a53 / aarch64_generic / x86_64
- 每目录：*.ipk 包 + Packages / Packages.gz / Packages.manifest / Packages.sig（usign 签名）

### apk 分支（OpenWrt 25.x）
- 3 架构目录同上
- 每目录：*.apk 包 + packages.adb（EC P-256 签名）+ index.json

## 签名密钥体系（对齐 OpenWrt 官方）

| 格式 | 签名工具 | 私钥（签名） | 公钥（验证） |
| ---- | -------- | ------------ | ------------ |
| ipk | usign (Ed25519) | `key-build` | `key-build.pub` |
| apk | EC P-256 | `key-build.ec.key` | `key-build.pem` |

- 私钥在 GitHub Actions secrets：`KEY_BUILD`（usign 私钥）、`KEY_BUILD_EC`（EC 私钥）
- 公钥入库（master/key/ + gh-action-imagebuilder/key/），固件构建时预置：
  - 24.x → `/etc/opkg/keys/key-build.pub`
  - 25.x → `/etc/apk/keys/key-build.pem`
- 当前密钥指纹：`e1a9369072ae3a0d`（2026-08-10 轮换）

## sync-packages 工作流（自动同步 + 去重）

`.github/workflows/sync-packages.yml` 每天 16:00 UTC + 手动触发：

1. 下载 `MinimaxFlora/openwrt_package` 三个架构 release 的 *.ipk / *.apk
2. 从 secrets 注入签名私钥
3. 准备 ipk / apk 分支（不存在则创建 orphan 分支；自动清理误入分支的脚本/工具/密钥）
4. `sync_packages.py` 按插件名去重：同名插件（任意版本）先删旧再放新
5. `gen-index.sh --dir <分支>` 生成签名索引（脚本/工具/密钥均在 master 工作区，通过 KEY_DIR 指向）
6. 分别提交推送 ipk / apk 分支（无变更自动跳过）

## gen-index.sh 用法

```
./gen-index.sh                       # 处理当前目录所有架构子目录
./gen-index.sh x86_64                # 只处理指定架构
./gen-index.sh --dir /path/to/repo   # 指定仓库目录
```
- 密钥：公钥自动从 GitHub master 拉取；私钥必须本地存在
  （key/key-build + key/key-build.ec.key，可用环境变量 KEY_BUILD / KEY_BUILD_EC 覆盖）
- `KEY_DIR` 环境变量可指定密钥目录（工作流场景：私钥留在 master，分支不复制 key/）
- 工具优先用项目内 tools/，缺失才回退 ImageBuilder（IB_PATH 可指定）

## 新增/更新插件包流程

### 手动方式
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
3. 重新生成索引（脚本/工具/密钥在 master，用 --dir + KEY_DIR）：
   ```
   KEY_DIR=<master 的 key 路径> KEY_BUILD=<usign 私钥> KEY_BUILD_EC=<EC 私钥> \
   bash <master>/gen-index.sh --dir /tmp/ep-repo
   ```
4. 推送两个分支：`git push origin ipk apk`
5. 验证：`git ls-tree -r --name-only origin/ipk | grep 包名` + 确认 Packages.sig/packages.adb 签名验证 OK

### 自动方式（推荐）
直接触发 sync-packages 工作流（手动 Run workflow），自动完成下载→去重→索引→推送。

## 注意
- 索引必须重新生成，否则 opkg/apk 装不上新包
- 私钥永不入库；公钥只放 master/key/ 与 gh-action-imagebuilder/key/
- 验证结果应显示 "usign 签名验证 OK" / "EC 签名验证 OK"
- 依赖来源：openwrt_package 的 build-packages 工作流按架构发布 ipk/apk 到 release，
  本仓库工作流从 release 拉取并维护签名索引
