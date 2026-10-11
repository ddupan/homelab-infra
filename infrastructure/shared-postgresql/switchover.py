#!/usr/bin/env python3
"""计划内切换 pg-prod 主库，默认回切到 laptop。在 laptop 上运行，不加 --run 只做预检。

laptop 重启后 Patroni 会自动把主库切到 pg-pve1（HDD），触发 SharedPostgresPrimaryOnStandbyHost。
切换期间生产写入中断数秒（2026-09-25 演练约 9 秒）；入口代理跟随 Patroni /primary，客户端不用改。
"""
import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

PATRONICTL = ['sudo', '-n', '-u', 'pgprod', '/opt/homelab-patroni/bin/patronictl',
              '-c', '/etc/homelab-postgresql/prod/patroni.yml']
# 与 Patroni maximum_lag_on_failover 一致：副本落后更多就不切，避免丢已提交的事务。
MAX_LAG_BYTES = 1024 * 1024


def members():
    result = subprocess.run(PATRONICTL + ['list', '-f', 'json'],
                            capture_output=True, text=True, check=True)
    return {m['Member']: m for m in json.loads(result.stdout)}


def preflight(members, candidate):
    """返回当前 Leader 的成员名；不满足切换前提时抛 SystemExit 说明原因。"""
    leaders = [m for m in members.values() if m['Role'] == 'Leader']
    if len(leaders) != 1:
        raise SystemExit(f'需要恰好一个 Leader，当前: {[m["Member"] for m in leaders]}')
    leader = leaders[0]
    target = members.get(candidate)
    if target is None:
        raise SystemExit(f'找不到成员 {candidate}')
    if target is leader:
        raise SystemExit(f'{candidate} 已经是 Leader，无需切换')
    if target['State'] != 'streaming':
        raise SystemExit(f'{candidate} 状态为 {target["State"]}，不是 streaming')
    if target['TL'] != leader['TL']:
        raise SystemExit(f'时间线不一致: {candidate}={target["TL"]}，Leader={leader["TL"]}')
    lag = max(target.get('Receive Lag') or 0, target.get('Replay Lag') or 0)
    if lag > MAX_LAG_BYTES:
        raise SystemExit(f'{candidate} 落后 {lag} 字节，超过 {MAX_LAG_BYTES}')
    return leader['Member']


def is_primary(host):
    try:
        with urllib.request.urlopen(f'http://{host}:8008/primary', timeout=2) as response:
            return response.status == 200
    except urllib.error.URLError:  # 非 primary 返回 503，也落在这里
        return False


def wait_until(check, description, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            print('✓', description)
            return
        time.sleep(1)
    raise SystemExit(f'✗ {description}：{timeout} 秒内未达成')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--candidate', default='pg-laptop',
                        help='切换后的 Leader（默认 pg-laptop；维护 laptop 前可用 pg-pve1 主动切走）')
    parser.add_argument('--run', action='store_true', help='执行切换；不加只做预检')
    args = parser.parse_args()

    subprocess.run(PATRONICTL + ['list'], check=True)
    current = members()
    leader = preflight(current, args.candidate)
    print(f'预检通过：Leader 将从 {leader} 切换到 {args.candidate}。')
    if not args.run:
        print('未执行。确认后加 --run。')
        return

    subprocess.run(PATRONICTL + ['switchover', '--leader', leader,
                                 '--candidate', args.candidate, '--force'], check=True)
    wait_until(lambda: is_primary(current[args.candidate]['Host']),
               f'{args.candidate} 成为 primary', timeout=60)
    wait_until(lambda: all(m['State'] == 'streaming'
                           for m in members().values() if m['Role'] != 'Leader'),
               '其余成员恢复 streaming', timeout=120)
    subprocess.run(PATRONICTL + ['list'], check=True)


if __name__ == '__main__':
    sys.exit(main())
