#!/bin/bash
# TriSignal Trader V4.0 — 系统 crontab 触发
# 北京时间 11/15/19/23/03/07:07 执行，Claude Code skill 模式

LOG_DIR="/Users/bytedance/.claude/skills/trisignal-trader/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/trisignal_${TIMESTAMP}.log"

echo "[$(date)] Starting TriSignal V4.0..." >> "$LOG_FILE"

cd /Users/bytedance/Documents/claude/okx && \
  /Users/bytedance/.local/bin/claude -p "/trisignal-trader" >> "$LOG_FILE" 2>&1

EXIT_CODE=$?
echo "[$(date)] Done (exit=$EXIT_CODE)." >> "$LOG_FILE"

# macOS 通知
osascript -e 'display notification "TriSignal 跑完啦～ 快来看结果！" with title "OKX Trading Bot" sound name "Blow"' 2>/dev/null || true
