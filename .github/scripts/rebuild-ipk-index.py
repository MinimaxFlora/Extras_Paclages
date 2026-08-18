#!/usr/bin/env python3
"""重建 OpenWrt ipk 仓库索引：Packages / Packages.gz / Packages.manifest
按 control 字段 + 实际文件哈希生成，Filename 用 <archdir>/<name>.ipk 格式。
"""
import io
import gzip
import hashlib
import os
import sys
import tarfile


def read_control(ipk_path):
    """从 ipk 中读取 control 文件内容"""
    try:
        with tarfile.open(ipk_path, 'r:*') as tf:
            for m in tf.getmembers():
                if m.name in ('control.tar.gz', './control.tar.gz'):
                    data = tf.extractfile(m).read()
                    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as ctf:
                        for cm in ctf.getmembers():
                            if cm.name in ('control', './control'):
                                return ctf.extractfile(cm).read().decode('utf-8', 'replace')
    except Exception:
        return None
    return None


def parse_control(text):
    """解析 control 为有序字段列表，Description 单独保留（可能是多行）"""
    fields = []
    desc = None
    cur_key = None
    cur_val = []
    for raw in text.splitlines():
        if raw.startswith(' ') and cur_key is not None:
            cur_val.append(raw[1:])
            continue
        if cur_key is not None:
            if cur_key.lower() == 'description':
                desc = '\n'.join(cur_val)
            else:
                fields.append((cur_key, '\n'.join(cur_val)))
        if ':' in raw:
            cur_key, v = raw.split(':', 1)
            cur_val = [v.lstrip(' ')]
        else:
            cur_key = None
    if cur_key is not None:
        if cur_key.lower() == 'description':
            desc = '\n'.join(cur_val)
        else:
            fields.append((cur_key, '\n'.join(cur_val)))
    return fields, desc


def main(archdir):
    ipk_files = sorted(f for f in os.listdir(archdir) if f.endswith('.ipk'))
    entries = []
    manifests = []
    for name in ipk_files:
        path = os.path.join(archdir, name)
        control = read_control(path)
        if control is None:
            print(f'!! 无法读取 control: {name}')
            continue
        fields, desc = parse_control(control)
        # 去掉已有的 Filename/Size/SHA256sum（若有）
        fields = [(k, v) for k, v in fields
                  if k.lower() not in ('filename', 'size', 'sha256sum', 'md5sum')]
        size = os.path.getsize(path)
        sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()

        lines = []
        for k, v in fields:
            lines.append(f'{k}: {v}')
        lines.append(f'Filename: {archdir}/{name}')
        lines.append(f'Size: {size}')
        lines.append(f'SHA256sum: {sha}')
        if desc is not None:
            # Description 多行：首行跟随，续行前加空格
            dl = desc.split('\n')
            lines.append(f'Description: {dl[0]}')
            for extra in dl[1:]:
                lines.append(f' {extra}')
        entries.append('\n'.join(lines))

        mlines = [f'{k}: {v}' for k, v in fields]
        if desc is not None:
            dl = desc.split('\n')
            mlines.append(f'Description: {dl[0]}')
            for extra in dl[1:]:
                mlines.append(f' {extra}')
        manifests.append('\n'.join(mlines))

    packages = '\n\n'.join(entries) + '\n'
    manifest = '\n\n'.join(manifests) + '\n'

    with open(os.path.join(archdir, 'Packages'), 'w') as f:
        f.write(packages)
    # 确定性 gzip（mtime=0），保证重复运行时输出字节一致，避免无谓提交
    with open(os.path.join(archdir, 'Packages.gz'), 'wb') as f:
        with gzip.GzipFile(fileobj=f, mode='wb', mtime=0) as gz:
            gz.write(packages.encode())
    with open(os.path.join(archdir, 'Packages.manifest'), 'w') as f:
        f.write(manifest)
    # 旧签名已失效（对应旧索引），删除
    sig = os.path.join(archdir, 'Packages.sig')
    if os.path.exists(sig):
        os.remove(sig)
        print(f'!! 已删除失效的 {archdir}/Packages.sig（旧索引签名）')
    print(f'{archdir}: {len(ipk_files)} 个包，索引已重建')


if __name__ == '__main__':
    for d in sys.argv[1:]:
        if not os.path.isdir(d):
            print(f'{d}: 目录不存在，跳过')
            continue
        if not any(f.endswith('.ipk') for f in os.listdir(d)):
            print(f'{d}: 无 ipk 文件，跳过')
            continue
        main(d)
