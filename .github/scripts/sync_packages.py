#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
同步 openwrt_package release 插件包到 Extras_Paclages 的 ipk / apk 分支。

用法:
  sync_packages.py <下载目录> <ipk 分支目录> <apk 分支目录>

下载目录结构: <下载目录>/<架构>/*.ipk|*.apk
  (架构: x86_64 / aarch64_generic / aarch64_cortex-a53)

规则:
1. 按插件名去重: 目标目录里同名的旧版本先删再放新的
2. 镜像清理: 目标目录里存在、但本次 release 里根本没有的插件包一律删除
   （历史上从别的源混进来的 dae / kcptun / ssr-plus 之类，以及早就没人编的旧包）
   如果某个架构本次一个包都没下载到（release 缺失），则跳过该架构的清理，
   避免把整条 feed 清空。
"""
import os
import shutil
import sys

ARCHS = ['x86_64', 'aarch64_generic', 'aarch64_cortex-a53']


def parse_ipk(fn):
    """luci-app-quickfile_1.0.0-r1_all.ipk -> (name, version)"""
    base = fn[:-4]  # 去掉 .ipk
    parts = base.rsplit('_', 2)
    if len(parts) == 3 and parts[2]:
        return parts[0], parts[1]
    return None


def parse_apk(fn):
    """luci-app-quickfile-1.0.0-r1.apk -> (name, version)

    apk 文件名格式: <name>-<version>.apk，其中版本号以数字开头且可能含连字符
    （如 1.0.0-r1）。从右往左找第一个以数字开头的段作为版本起点。
    """
    base = fn[:-4]  # 去掉 .apk
    parts = base.split('-')
    for i in range(len(parts) - 1, -1, -1):
        if parts[i] and parts[i][0].isdigit():
            name = '-'.join(parts[:i])
            version = '-'.join(parts[i:])
            if name:
                return name, version
    return None


def sync_kind(kind, dl_dir, repo_dir):
    changed = 0
    for arch in ARCHS:
        src = os.path.join(dl_dir, arch)
        dst = os.path.join(repo_dir, arch)
        if not os.path.isdir(src):
            print(f'  !! 跳过 {arch}: 下载目录不存在')
            continue
        os.makedirs(dst, exist_ok=True)

        parse = parse_ipk if kind == 'ipk' else parse_apk
        ext = '.' + kind

        # 收集本次要同步的新文件
        new_files = []
        for fn in sorted(os.listdir(src)):
            if not fn.endswith(ext):
                continue
            parsed = parse(fn)
            if not parsed:
                print(f'  !! 无法解析文件名: {arch}/{fn}')
                continue
            new_files.append((fn, parsed))

        expected = {name for _fn, (name, _ver) in new_files}

        # 按插件名去重：删除目标目录中的同名旧文件
        for fn, (name, ver) in new_files:
            for existing in list(os.listdir(dst)):
                if existing == fn or not existing.endswith(ext):
                    continue
                ep = parse(existing)
                if ep and ep[0] == name:
                    os.remove(os.path.join(dst, existing))
                    print(f'  [删旧] {arch}/{existing}  ->  替换为 {fn}')
                    changed += 1

        # 放入新文件（内容相同则跳过，避免无意义提交）
        for fn, (name, ver) in new_files:
            srcf = os.path.join(src, fn)
            dstf = os.path.join(dst, fn)
            if os.path.exists(dstf) and os.path.getsize(dstf) == os.path.getsize(srcf):
                print(f'  [不变] {arch}/{fn}')
                continue
            shutil.copy2(srcf, dstf)
            print(f'  [新增] {arch}/{fn}  (v{ver})')
            changed += 1

        # 镜像清理：本次 release 里没有的插件包，全部删掉
        if not expected:
            print(f'  !! {arch}: 本次没有下载到任何 {kind}，跳过清理')
            continue
        for existing in sorted(os.listdir(dst)):
            if not existing.endswith(ext):
                continue
            ep = parse(existing)
            if ep is None:
                print(f'  [警告] 无法解析、保留: {arch}/{existing}')
                continue
            if ep[0] not in expected:
                os.remove(os.path.join(dst, existing))
                print(f'  [清理] {arch}/{existing}（本次 release 里没有这个插件）')
                changed += 1

    return changed


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    dl_dir, repo_ipk, repo_apk = sys.argv[1], sys.argv[2], sys.argv[3]

    total = 0
    print('==== ipk 分支 ====')
    total += sync_kind('ipk', dl_dir, repo_ipk)
    print('==== apk 分支 ====')
    total += sync_kind('apk', dl_dir, repo_apk)
    print(f'==== 完成，变更文件数: {total} ====')


if __name__ == '__main__':
    main()
