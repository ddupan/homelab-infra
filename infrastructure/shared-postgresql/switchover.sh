#!/usr/bin/env bash
# 计划内切换 pg-prod 主库（默认回切到 laptop）。在 laptop 上运行：
#   infrastructure/shared-postgresql/switchover.sh          # 只预检，打印将要执行的切换
#   infrastructure/shared-postgresql/switchover.sh --run    # 执行
#   CANDIDATE=pg-pve1 infrastructure/shared-postgresql/switchover.sh --run   # 计划内切到 pve1
#
# 典型场景：laptop 重启后 Patroni 已自动把主库切到 pg-pve1（HDD），触发
# SharedPostgresPrimaryOnStandbyHost。切换期间生产写入中断数秒（2026-09-25 演练约 9 秒），
# 入口代理按 Patroni /primary 跟随，无需改连接串。命令与 tests/live_failover.py 的回切一致。
set -euo pipefail

CANDIDATE="${CANDIDATE:-pg-laptop}"
# 与 Patroni maximum_lag_on_failover 一致：副本落后超过它就不切，避免丢已提交事务。
MAX_LAG_BYTES=1048576
PATRONICTL=(sudo -n -u pgprod /opt/homelab-patroni/bin/patronictl -c /etc/homelab-postgresql/prod/patroni.yml)

members() { "${PATRONICTL[@]}" list -f json 2>/dev/null; }

# 打印 "leader candidate_host"；不满足切换前提时以非零退出并说明原因。
preflight() {
  members | python3 -c '
import json, sys
candidate, max_lag = sys.argv[1], int(sys.argv[2])
ms = json.load(sys.stdin)
leaders = [m for m in ms if m["Role"] == "Leader"]
if len(leaders) != 1:
    sys.exit("需要恰好一个 Leader，当前: %s" % [m["Member"] for m in leaders])
c = next((m for m in ms if m["Member"] == candidate), None)
if c is None:
    sys.exit("找不到成员 %s" % candidate)
if c["Role"] == "Leader":
    sys.exit("%s 已经是 Leader，无需切换" % candidate)
if c["State"] != "streaming":
    sys.exit("%s 状态为 %s，不是 streaming" % (candidate, c["State"]))
if c["TL"] != leaders[0]["TL"]:
    sys.exit("时间线不一致: %s=%s, Leader=%s" % (candidate, c["TL"], leaders[0]["TL"]))
lag = max(c.get("Receive Lag") or 0, c.get("Replay Lag") or 0)
if lag > max_lag:
    sys.exit("%s 落后 %d 字节，超过 %d" % (candidate, lag, max_lag))
print(leaders[0]["Member"], c["Host"])
' "$CANDIDATE" "$MAX_LAG_BYTES"
}

wait_for() {  # wait_for <描述> <超时秒> <命令...>
  local what=$1 timeout=$2; shift 2
  for _ in $(seq "$timeout"); do "$@" && { echo "  ✓ $what"; return 0; }; sleep 1; done
  echo "  ✗ $what：${timeout}s 内未达成" >&2; return 1
}
is_primary() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$1:8008/primary")" = 200 ]; }
all_streaming() { members | python3 -c 'import json,sys; ms=json.load(sys.stdin); sys.exit(0 if all(m["State"]=="streaming" for m in ms if m["Role"]!="Leader") else 1)'; }

"${PATRONICTL[@]}" list 2>/dev/null
read -r leader host < <(preflight) || exit 1
echo "预检通过：将把 Leader 从 $leader 切换到 $CANDIDATE（$host）。"

if [ "${1:-}" != "--run" ]; then
  echo "未执行。确认后加 --run。"
  exit 0
fi

"${PATRONICTL[@]}" switchover --leader "$leader" --candidate "$CANDIDATE" --force
wait_for "$CANDIDATE 成为 primary" 60 is_primary "$host"
wait_for "其余成员恢复 streaming" 120 all_streaming
"${PATRONICTL[@]}" list 2>/dev/null
echo "完成。SharedPostgresPrimaryOnStandbyHost 会在下次评估后消失。"
