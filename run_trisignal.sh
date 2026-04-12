#!/bin/bash
# TriSignal Trader V4.1 — 并行预拉数据，减少 Claude 执行时间

source /Users/bytedance/.zshrc 2>/dev/null || true
export PATH="/Users/bytedance/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

LOG_DIR="/Users/bytedance/.claude/skills/trisignal-trader/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/trisignal_${TIMESTAMP}.log"

# ── 防并发锁（run_lock）─────────────────────────────────────────────────────
# 同一时刻只允许一个 TriSignal 实例运行（防止 4h cron 与手动运行冲突）
LOCK_FILE="$LOG_DIR/trisignal.lock"
# macOS 没有 flock，用 python3 原子锁
if python3 -c "
import sys, os
lf = sys.argv[1]
try:
    fd = os.open(lf, os.O_CREAT|os.O_EXCL|os.O_WRONLY)
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)
    sys.exit(0)
except FileExistsError:
    pid = open(lf).read().strip()
    try:
        os.kill(int(pid), 0)
        sys.exit(1)  # still running
    except (ProcessLookupError, ValueError):
        os.unlink(lf)
        sys.exit(0)  # stale lock, remove and proceed
" "$LOCK_FILE"; then
    trap 'rm -f "$LOCK_FILE"' EXIT
else
    echo "[$(date)] [run_lock] Already running (another instance holds the lock). Skipping." >> "$LOG_FILE"
    exit 0
fi

echo "[$(date)] Starting TriSignal V4.1 (parallel data fetch)..." >> "$LOG_FILE"
osascript -e 'display notification "开始采集数据 + 评分决策..." with title "TriSignal 启动" sound name "Tink"' 2>/dev/null || true

# ── 并行拉取所有数据（~5s 完成，替代 Claude 串行调用的 ~60s）──────────────
TMPDIR=$(mktemp -d)
TMPDIR_OUT=$(mktemp -d)

okx market indicator ma   BTC-USDT-SWAP --bar 4H --params 5,10,20,60 --limit 1 > "$TMPDIR/btc_ma"   2>&1 &
okx market indicator macd BTC-USDT-SWAP --bar 4H --limit 1                      > "$TMPDIR/btc_macd" 2>&1 &
okx market indicator atr  BTC-USDT-SWAP --bar 4H --params 14 --limit 1          > "$TMPDIR/btc_atr"  2>&1 &
okx market indicator ma   ETH-USDT-SWAP --bar 4H --params 5,10,20,60 --limit 1 > "$TMPDIR/eth_ma"   2>&1 &
okx market indicator macd ETH-USDT-SWAP --bar 4H --limit 1                      > "$TMPDIR/eth_macd" 2>&1 &
okx market indicator atr  ETH-USDT-SWAP --bar 4H --params 14 --limit 1          > "$TMPDIR/eth_atr"  2>&1 &
okx market indicator ma   SOL-USDT-SWAP --bar 4H --params 5,10,20,60 --limit 1 > "$TMPDIR/sol_ma"   2>&1 &
okx market indicator macd SOL-USDT-SWAP --bar 4H --limit 1                      > "$TMPDIR/sol_macd" 2>&1 &
okx market indicator atr  SOL-USDT-SWAP --bar 4H --params 14 --limit 1          > "$TMPDIR/sol_atr"  2>&1 &
okx market indicator ma   XRP-USDT-SWAP --bar 4H --params 5,10,20,60 --limit 1 > "$TMPDIR/xrp_ma"   2>&1 &
okx market indicator macd XRP-USDT-SWAP --bar 4H --limit 1                      > "$TMPDIR/xrp_macd" 2>&1 &
okx market indicator atr  XRP-USDT-SWAP --bar 4H --params 14 --limit 1          > "$TMPDIR/xrp_atr"  2>&1 &
okx market funding-rate BTC-USDT-SWAP > "$TMPDIR/btc_fr" 2>&1 &
okx market funding-rate ETH-USDT-SWAP > "$TMPDIR/eth_fr" 2>&1 &
okx market funding-rate SOL-USDT-SWAP > "$TMPDIR/sol_fr" 2>&1 &
okx market funding-rate XRP-USDT-SWAP > "$TMPDIR/xrp_fr" 2>&1 &
okx market open-interest --instType SWAP --instId BTC-USDT-SWAP > "$TMPDIR/btc_oi" 2>&1 &
okx market open-interest --instType SWAP --instId ETH-USDT-SWAP > "$TMPDIR/eth_oi" 2>&1 &
okx market open-interest --instType SWAP --instId SOL-USDT-SWAP > "$TMPDIR/sol_oi" 2>&1 &
okx market open-interest --instType SWAP --instId XRP-USDT-SWAP > "$TMPDIR/xrp_oi" 2>&1 &
okx market open-interest --instType SWAP --instId BTC-USDT-SWAP --history --limit 2 > "$TMPDIR/btc_oi_hist" 2>&1 &
okx market open-interest --instType SWAP --instId ETH-USDT-SWAP --history --limit 2 > "$TMPDIR/eth_oi_hist" 2>&1 &
okx market open-interest --instType SWAP --instId SOL-USDT-SWAP --history --limit 2 > "$TMPDIR/sol_oi_hist" 2>&1 &
okx market open-interest --instType SWAP --instId XRP-USDT-SWAP --history --limit 2 > "$TMPDIR/xrp_oi_hist" 2>&1 &
okx --profile okx-live account balance USDT                      > "$TMPDIR/balance" 2>&1 &
okx --profile okx-live swap positions                            > "$TMPDIR/positions" 2>&1 &

wait  # 等所有并行任务完成
echo "[$(date)] Data fetch complete." >> "$LOG_FILE"

# ── 组装 prompt ────────────────────────────────────────────────────────────
PROMPT=$(cat <<PROMPT
以下是已预先采集好的最新市场数据（4H bar），请直接跳过 Step 1 和 Step 2 的数据采集，从 Step 3 评分开始执行 trisignal-trader 策略。

=== BTC-USDT-SWAP ===
MA: $(cat $TMPDIR/btc_ma)
MACD: $(cat $TMPDIR/btc_macd)
ATR: $(cat $TMPDIR/btc_atr)
Funding: $(cat $TMPDIR/btc_fr)
OI: $(cat $TMPDIR/btc_oi)
OI历史(用于变化方向判断): $(cat $TMPDIR/btc_oi_hist 2>/dev/null || echo "UNAVAILABLE")

=== ETH-USDT-SWAP ===
MA: $(cat $TMPDIR/eth_ma)
MACD: $(cat $TMPDIR/eth_macd)
ATR: $(cat $TMPDIR/eth_atr)
Funding: $(cat $TMPDIR/eth_fr)
OI: $(cat $TMPDIR/eth_oi)
OI历史(用于变化方向判断): $(cat $TMPDIR/eth_oi_hist 2>/dev/null || echo "UNAVAILABLE")

=== SOL-USDT-SWAP ===
MA: $(cat $TMPDIR/sol_ma)
MACD: $(cat $TMPDIR/sol_macd)
ATR: $(cat $TMPDIR/sol_atr)
Funding: $(cat $TMPDIR/sol_fr)
OI: $(cat $TMPDIR/sol_oi)
OI历史(用于变化方向判断): $(cat $TMPDIR/sol_oi_hist 2>/dev/null || echo "UNAVAILABLE")

=== XRP-USDT-SWAP ===
MA: $(cat $TMPDIR/xrp_ma)
MACD: $(cat $TMPDIR/xrp_macd)
ATR: $(cat $TMPDIR/xrp_atr)
Funding: $(cat $TMPDIR/xrp_fr)
OI: $(cat $TMPDIR/xrp_oi)
OI历史(用于变化方向判断): $(cat $TMPDIR/xrp_oi_hist 2>/dev/null || echo "UNAVAILABLE")

=== 账户信息 ===
余额: $(cat $TMPDIR/balance)
当前持仓: $(cat $TMPDIR/positions)

=== 事件面底色（由 Daily Review 生成，Chainbase 社交数据驱动）===
$(cat /Users/bytedance/.claude/skills/trisignal-trader/event_context.txt 2>/dev/null || echo "无事件面数据，Dimension 7 按中性5分处理")

=== 上一轮 Snapshot（用于信号恶化连续性判断）===
$(ls -t /Users/bytedance/.claude/skills/trisignal-trader/records/snapshot_*.json 2>/dev/null | head -1 | xargs cat 2>/dev/null || echo "无上一轮记录")
PROMPT
)

rm -rf "$TMPDIR"

# ── 调用 Claude 执行策略（只做分析+决策+下单，跳过数据采集）──────────────
CLAUDE_OUTPUT_FILE="$TMPDIR_OUT/claude_output"
mkdir -p "$TMPDIR_OUT"

cd /Users/bytedance/Documents/claude/okx && \
  /Users/bytedance/.local/bin/claude -p "/trisignal-trader

$PROMPT" 2>&1 | tee -a "$LOG_FILE" > "$CLAUDE_OUTPUT_FILE"

EXIT_CODE=${PIPESTATUS[0]}

# ── 从 Claude 输出中提取并写入记录文件 ────────────────────────────────────
RECORDS_DIR="/Users/bytedance/.claude/skills/trisignal-trader/records"
mkdir -p "$RECORDS_DIR"
TS_FILE=$(date +"%Y%m%d_%H%M")

# 提取 snapshot
SNAPSHOT_JSON=$(awk '/^%%SNAPSHOT_BEGIN%%/{found=1; next} /^%%SNAPSHOT_END%%/{found=0} found{print}' "$CLAUDE_OUTPUT_FILE")
if [ -n "$SNAPSHOT_JSON" ]; then
  echo "$SNAPSHOT_JSON" > "$RECORDS_DIR/snapshot_${TS_FILE}.json"
  echo "[$(date)] Snapshot written: snapshot_${TS_FILE}.json" >> "$LOG_FILE"
else
  echo "[$(date)] WARNING: No snapshot marker found in Claude output" >> "$LOG_FILE"
fi

# 提取 trade record（仅开仓时存在）
TRADE_JSON=$(awk '/^%%TRADE_BEGIN%%/{found=1; next} /^%%TRADE_END%%/{found=0} found{print}' "$CLAUDE_OUTPUT_FILE")
if [ -n "$TRADE_JSON" ]; then
  echo "$TRADE_JSON" > "$RECORDS_DIR/trade_${TS_FILE}.json"
  echo "[$(date)] Trade record written: trade_${TS_FILE}.json" >> "$LOG_FILE"
fi

rm -rf "$TMPDIR_OUT"
echo "[$(date)] Done (exit=$EXIT_CODE)." >> "$LOG_FILE"

# 提取决策结果用于通知
DECISION=$(grep -oP '"decision"\s*:\s*"\K[^"]+' "$RECORDS_DIR/snapshot_${TS_FILE}.json" 2>/dev/null | head -1)
BEST=$(grep -oP '"best"\s*:\s*"\K[^"]+' "$RECORDS_DIR/snapshot_${TS_FILE}.json" 2>/dev/null | head -1)
NOTIF_MSG="${DECISION:-完成} ${BEST:+($BEST)}"
osascript -e "display notification \"$NOTIF_MSG\" with title \"TriSignal 结果\" sound name \"Blow\"" 2>/dev/null || true
