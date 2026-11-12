#!/usr/bin/env python3
"""从 `flate diff -o json` 提取 CRD 变更，输出 Markdown 摘要表（不贴 CRD 全文）。

  flate diff ... --skip-kinds Secret -o json | crd_summary.py

CRD 全文 diff 动辄数千行，评论放不下；判断升级风险需要的是：哪些 CRD 增删、
哪个版本不再 served 或换了 storage 版本（已存对象需要迁移）、schema 有没有变。
无 CRD 变更时不输出任何内容。
"""
import json
import sys


def versions(crd):
    return {v['name']: v for v in ((crd or {}).get('spec') or {}).get('versions') or []}


def flags(v):
    return '/'.join(f for f in ('served', 'storage') if v.get(f)) or '未 served'


def describe(change):
    """返回 (是否危险, 说明列表)。"""
    old, new = change.get('old'), change.get('new')
    if change['status'] == 'added':
        return False, ['新增，版本 ' + ', '.join(versions(new))]
    if change['status'] == 'removed':
        # Flux prune 掉 CRD 会连带删除集群里该类型的全部对象。
        return True, ['删除（集群内该类型对象会一并删除）']
    ov, nv = versions(old), versions(new)
    danger, notes = False, []
    for name in sorted(ov.keys() | nv.keys()):
        o, n = ov.get(name), nv.get(name)
        if o is None:
            notes.append(f'`{name}` 新增（{flags(n)}）')
        elif n is None:
            danger = True
            notes.append(f'`{name}` 移除')
        else:
            if flags(o) != flags(n):
                # 停止 served 或 storage 版本迁移，都可能让现有对象读不出来。
                danger = danger or (o.get('served') and not n.get('served')) or o.get('storage') != n.get('storage')
                notes.append(f'`{name}` {flags(o)} → {flags(n)}')
            if (o.get('schema') or {}) != (n.get('schema') or {}):
                notes.append(f'`{name}` schema 变化')
    other = {k for k in (old.get('spec') or {}) | (new.get('spec') or {})
             if k != 'versions' and (old.get('spec') or {}).get(k) != (new.get('spec') or {}).get(k)}
    if other:
        notes.append('spec 其他字段：' + ', '.join(f'`{k}`' for k in sorted(other)))
    return danger, notes or ['仅元数据变化']


def summarize(doc):
    rows = []
    for c in doc.get('changes') or []:
        if c.get('kind') != 'CustomResourceDefinition':
            continue
        danger, notes = describe(c)
        rows.append(f"| {'⚠️ ' if danger else ''}`{c['name']}` | {'<br>'.join(notes)} |")
    if not rows:
        return ''
    return '#### CRD 变更\n\n| CRD | 变化 |\n|---|---|\n' + '\n'.join(rows) + '\n\n'


if __name__ == '__main__':
    sys.stdout.write(summarize(json.load(sys.stdin)))
