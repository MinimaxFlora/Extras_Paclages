# Extras_Paclages

第三方 OpenWrt 插件包仓库，供 [gh-action-imagebuilder](https://github.com/MinimaxFlora/gh-action-imagebuilder)
构建固件时自动导入，也可作为独立的 opkg / apk 软件源使用。

## 分支结构

| 分支 | 用途 | 包格式 | 索引文件 |
| ---- | ---- | ------ | -------- |
| `ipk` | OpenWrt 24.x（opkg） | `.ipk` | `Packages` / `Packages.gz` / `Packages.manifest` / `Packages.sig` |
| `apk` | OpenWrt 25.x（apk） | `.apk` | `packages.adb` / `index.json` |
| `master` | 文档 + 签名密钥 + 脚本 | - | - |

包分支均按目标架构分类，每个架构目录内直接存放插件包，并包含该架构的**签名索引**：

```
apk (或 ipk)/
├── x86_64/              # x86-64 架构
├── aarch64_generic/     # rockchip armv8（如 nanopi R4S 等）
└── aarch64_cortex-a53/  # 其他 aarch64 设备
```

```
master/
├── README.md
├── gen-index.sh             # 索引生成脚本
└── key/
    ├── key-build.pem        # EC P-256 公钥（验证 apk 索引/包签名）
    └── key-build.pub        # usign Ed25519 公钥（验证 ipk 索引/包签名）
```

## 使用方式

### 作为插件源（构建固件）

gh-action-imagebuilder 会根据 `version` 自动选择分支（24.x → `ipk`，25.x → `apk`），
并只导入与目标架构匹配的文件夹（`x86-64` → `x86_64`，`rockchip-armv8` → `aarch64_generic`）。

### 作为独立 opkg / apk 源

把仓库对应的分支/架构目录配成软件源，并用 `key/` 下的公钥开启签名校验：

```sh
# opkg (24.x) — /etc/opkg/customfeeds.conf
src/gz extras_packages https://raw.githubusercontent.com/MinimaxFlora/Extras_Paclages/ipk/x86_64
```

```sh
# apk (25.x) — /etc/apk/repositories.d/ 下新建源文件
https://raw.githubusercontent.com/MinimaxFlora/Extras_Paclages/apk/x86_64
```

## 脚本使用

### gen-index.sh — 生成签名索引

为 ipk / apk 分支的各个架构生成带签名的仓库索引。新增或更新插件后运行本脚本刷新索引。

```bash
# 基本用法（在 ipk 或 apk 分支目录下运行）
./gen-index.sh                       # 处理当前目录下全部架构
./gen-index.sh x86_64                # 只处理指定架构
./gen-index.sh aarch64_generic aarch64_cortex-a53

# 指定仓库目录
./gen-index.sh --dir /path/to/Extras_Paclages
```

**签名体系**（与 OpenWrt 官方一致）：

| 分支 | 生成文件 | 签名算法 | 签名密钥 | 验证公钥 |
| ---- | -------- | -------- | -------- | -------- |
| ipk | `Packages.sig` | usign (Ed25519) | `key/key-build`（私钥） | `key/key-build.pub` |
| apk | `packages.adb` | EC P-256 | `key/key-build.ec.key`（私钥） | `key/key-build.pem` |

**密钥说明**：
- **公钥**（`key-build.pem` / `key-build.pub`）已入库，脚本在本地缺失时自动从仓库拉取
- **私钥**（`key-build` / `key-build.ec.key`）**不会入库**，需本地保留在 `key/` 目录，或用环境变量指定：

```bash
KEY_BUILD=/path/to/key-build \
KEY_BUILD_EC=/path/to/key-build.ec.key \
./gen-index.sh
```

**依赖**：ImageBuilder（内含 `usign` / `apk` / `mkhash` / `ipkg-make-index.sh`）。
脚本自动搜索常见路径，也可用 `IB_PATH` 指定：

```bash
IB_PATH=/path/to/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64 ./gen-index.sh
```

**输出**：
- ipk 架构目录：`Packages`、`Packages.gz`、`Packages.manifest`、`Packages.sig`
- apk 架构目录：`packages.adb`、`index.json`

## 添加新插件

1. 获取对应架构的 `.ipk` 或 `.apk` 插件包
2. 放入对应分支的架构文件夹：
   - 24.x → `ipk/<架构>/<插件>.ipk`
   - 25.x → `apk/<架构>/<插件>.apk`
3. 运行 `./gen-index.sh` 刷新该架构索引（含签名）
4. 提交并推送
