#!/bin/sh
# 测试用：验证云端会话能否访问 ccim hub（每台机器只触发一次，结果写进会话记录）。
input=$(cat)
echo "$input" | grep -q '"stop_hook_active": *true' && exit 0
marker="${TMPDIR:-/tmp}/qn-stop-probe-net-done"
[ -f "$marker" ] && exit 0
touch "$marker"
# 测试阶段 hub 是自签证书，先用 -k；正式版改为固定证书
result=$(curl -sk -m 20 -o /dev/null -w '%{http_code} %{time_total}s' -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"probe\":\"ccim\",\"session\":\"$CLAUDE_CODE_REMOTE_SESSION_ID\"}" \
  https://150.158.91.156/ccim-probe 2>&1)
code=$?
printf '{"decision":"block","reason":"[网络测试] curl 退出码 %s，结果 %s。请只回复一行：NET_PROBE 加上这两项。"}\n' "$code" "$result"
