#!/usr/bin/env python3
"""crd_summary 的回归检查：python3 .gitea/scripts/test_crd_summary.py"""
from crd_summary import summarize


def crd(*vers, scope='Namespaced'):
    return {'kind': 'CustomResourceDefinition', 'spec': {'scope': scope, 'versions': [
        {'name': n, 'served': s, 'storage': st, 'schema': {'openAPIV3Schema': sch}} for n, s, st, sch in vers]}}


def change(status, old, new, name='x.example.io'):
    return {'kind': 'CustomResourceDefinition', 'name': name, 'status': status, 'old': old, 'new': new}


assert summarize({'changes': [{'kind': 'Deployment', 'name': 'd', 'status': 'changed'}]}) == ''
assert summarize({'changes': []}) == ''

out = summarize({'changes': [change('added', None, crd(('v1', True, True, {})))]})
assert '新增，版本 v1' in out and '⚠️' not in out, out

out = summarize({'changes': [change('removed', crd(('v1', True, True, {})), None)]})
assert '⚠️' in out and '删除' in out, out

# 仅 schema 变化：不危险
out = summarize({'changes': [change('changed', crd(('v1', True, True, {'a': 1})), crd(('v1', True, True, {'a': 2})))]})
assert '`v1` schema 变化' in out and '⚠️' not in out, out

# storage 版本迁移 + 新增版本：危险
out = summarize({'changes': [change('changed',
                                    crd(('v1alpha1', True, True, {})),
                                    crd(('v1alpha1', True, False, {}), ('v1', True, True, {})))]})
assert '⚠️' in out and '`v1` 新增（served/storage）' in out and 'served/storage → served' in out, out

# 版本停止 served：危险
out = summarize({'changes': [change('changed', crd(('v1beta1', True, False, {}), ('v1', True, True, {})),
                                    crd(('v1beta1', False, False, {}), ('v1', True, True, {})))]})
assert '⚠️' in out and 'served → 未 served' in out, out

# 版本移除、spec 其他字段
out = summarize({'changes': [change('changed', crd(('v1beta1', True, False, {}), ('v1', True, True, {})),
                                    crd(('v1', True, True, {}), scope='Cluster'))]})
assert '⚠️' in out and '`v1beta1` 移除' in out and '`scope`' in out, out

# 仅元数据
out = summarize({'changes': [change('changed', crd(('v1', True, True, {})), crd(('v1', True, True, {})))]})
assert '仅元数据变化' in out, out

print('ok')
