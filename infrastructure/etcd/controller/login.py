#!/usr/bin/python3
"""仅由受控调用者捕获 stdout；不得手动运行以免在终端输出短期 token。"""
import json
import ssl
import sys
import urllib.request


def main():
    context = ssl.create_default_context()
    context.load_cert_chain('/etc/homelab-etcd/peer.crt', '/etc/homelab-etcd/peer.key')
    request = urllib.request.Request(
        'https://bao.lab.ddupan.top:8200/v1/auth/homelab-etcd-renewal/login',
        data=json.dumps({'name': 'etcd-laptop'}).encode(),
        headers={'Content-Type': 'application/json'}, method='POST',
    )
    with urllib.request.urlopen(request, context=context, timeout=30) as response:
        token = json.load(response)['auth']['client_token']
    if not isinstance(token, str) or not token:
        raise ValueError('empty token')
    sys.stdout.write(token)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Bao 响应和异常对象可能带敏感内容，不写入 journal。
        sys.stderr.write('Bao certificate login failed\n')
        sys.exit(1)
