#!/bin/sh
# 测试用：验证仓库里的 Stop 钩子在 Claude Code 云端会话里会不会执行。
# 每台机器只触发一次：让 Claude 再回复一句 HOOK_OK 和会话 ID，在会话记录里就能看到。
input=$(cat)
echo "$input" | grep -q '"stop_hook_active": *true' && exit 0
marker="${TMPDIR:-/tmp}/qn-stop-probe-done"
[ -f "$marker" ] && exit 0
touch "$marker"
printf '%s\n' '{"decision":"block","reason":"[Stop 钩子测试] 钩子已触发。请只回复一行：HOOK_OK 加上环境变量 CLAUDE_CODE_REMOTE_SESSION_ID 的值。"}'
