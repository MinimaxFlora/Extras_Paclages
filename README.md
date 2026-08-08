# Extras_Paclages

第三方 OpenWrt 插件包仓库，供 [gh-action-imagebuilder](https://github.com/MinimaxFlora/gh-action-imagebuilder) 构建固件时自动导入。

## 分支结构

| 分支 | 用途 | 包格式 |
| ---- | ---- | ------ |
| `ipk` | OpenWrt 24.x（opkg） | `.ipk` |
| `apk` | OpenWrt 25.x（apk） | `.apk` |

两个分支均按目标架构分类：

```
apk (或 ipk)/
├── x86_64/              # x86-64 架构
├── aarch64_generic/     # rockchip armv8（如 nanopi R4S 等）
└── aarch64_cortex-a53/  # 其他 aarch64 设备
```

每个架构文件夹内直接存放对应的插件包（`.ipk` / `.apk`），无需 `.run` 自解压包。

## 使用方式

gh-action-imagebuilder 会根据 `version` 自动选择分支（24.x → `ipk`，25.x → `apk`），
并只导入与目标架构匹配的文件夹（`x86-64` → `x86_64`，`rockchip-armv8` → `aarch64_generic`）。

## 添加新插件

1. 获取对应架构的 `.ipk` 或 `.apk` 插件包
2. 放入对应分支的架构文件夹：
   - 24.x → `ipk/<架构>/<插件>.ipk`
   - 25.x → `apk/<架构>/<插件>.apk`
3. 提交并推送
