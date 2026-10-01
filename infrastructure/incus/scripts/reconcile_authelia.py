#!/usr/bin/env python3
"""只协调 Incus client/policy，保留线上其他客户端、秘密和 claims 配置。"""
import argparse
import copy
import json
import subprocess
import tempfile
from pathlib import Path

import yaml


def merge(values, desired):
    result = copy.deepcopy(values)
    oidc = result['configMap']['identity_providers']['oidc']
    clients = oidc.setdefault('clients', [])
    for client in desired['clients']:
        matches = [i for i, old in enumerate(clients) if old['client_id'] == client['client_id']]
        if len(matches) > 1:
            raise ValueError('发现重复 client_id，拒绝自动覆盖')
        if matches:
            clients[matches[0]] = copy.deepcopy(client)
        else:
            clients.append(copy.deepcopy(client))
    oidc.setdefault('authorization_policies', {}).update(desired['authorization_policies'])
    return result


def run(args):
    # Helm 输出可能含秘密：只在内存处理，错误不回显正文。
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} {args[1]} 失败（退出码 {result.returncode}）；未输出可能含秘密的响应')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desired', required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    release = json.loads(run(['helm', 'list', '-n', 'authelia', '-o', 'json']))
    current = next(x for x in release if x['name'] == 'authelia')
    if current['chart'] != 'authelia-0.11.6' or current['status'] != 'deployed':
        raise RuntimeError('仅验证 authelia-0.11.6 且 release 必须 deployed；请先审阅版本变化')
    before = json.loads(run(['helm', 'get', 'values', 'authelia', '-n', 'authelia', '-o', 'json']))
    desired = yaml.safe_load(Path(args.desired).read_text())
    after = merge(before, desired)
    if before == after:
        print('changed=false: Incus client/policy 已收敛')
        return

    # 目录 0700，文件 0600，退出即清理；既有秘密不写入仓库或日志。
    with tempfile.TemporaryDirectory(prefix='incus-authelia-') as directory:
        root = Path(directory)
        path = root / 'values.json'
        path.touch(mode=0o600)
        path.write_text(json.dumps(after))
        run(['helm', 'pull', 'authelia/authelia', '--version', '0.11.6', '--destination', directory])
        chart = str(root / 'authelia-0.11.6.tgz')
        run(['helm', 'template', 'authelia', chart, '-n', 'authelia', '-f', str(path)])
        if args.check:
            print('changed=true: 将只更新 Incus client/policy；固定 chart 渲染通过')
            return
        latest = next(x for x in json.loads(run(['helm', 'list', '-n', 'authelia', '-o', 'json'])) if x['name'] == 'authelia')
        if latest['revision'] != current['revision'] or latest['status'] != 'deployed':
            raise RuntimeError('Authelia release 在准备期间变化，请重试，避免覆盖并发修改')
        run(['helm', 'upgrade', 'authelia', chart, '-n', 'authelia', '--reuse-values',
             '-f', str(path), '--atomic', '--timeout', '5m', '--history-max', '10'])
    print('changed=true: Incus client/policy 已部署，其他值保留')


if __name__ == '__main__':
    main()
