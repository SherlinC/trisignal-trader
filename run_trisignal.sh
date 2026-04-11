#!/bin/bash
# TriSignal Trader V4.1 — 并行预拉数据，减少 Claude 执行时间

source /Users/bytedance/.zshrc 2>/dev/null || true
export PATH="/Users/bytedance/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

LOG_DIR="/Users/bytedance/.claude/skills/trisignal-trader/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/trisignal_${TIMESTAMP}.log"

echo "[$(date)] Starting TriSignal V4.1 (parallel data fetch)..." >> "$LOG_FILE"

# ── 并行拉取所有数据（~5s 完成，替代 Claude 串行调用的 ~60s）──────────────
TMPDIR=$(mktemp -d)

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

=== ETH-USDT-SWAP ===
MA: $(cat $TMPDIR/eth_ma)
MACD: $(cat $TMPDIR/eth_macd)
ATR: $(cat $TMPDIR/eth_atr)
Funding: $(cat $TMPDIR/eth_fr)
OI: $(cat $TMPDIR/eth_oi)

=== SOL-USDT-SWAP ===
MA: $(cat $TMPDIR/sol_ma)
MACD: $(cat $TMPDIR/sol_macd)
ATR: $(cat $TMPDIR/sol_atr)
Funding: $(cat $TMPDIR/sol_fr)
OI: $(cat $TMPDIR/sol_oi)

=== XRP-USDT-SWAP ===
MA: $(cat $TMPDIR/xrp_ma)
MACD: $(cat $TMPDIR/xrp_macd)
ATR: $(cat $TMPDIR/xrp_atr)
Funding: $(cat $TMPDIR/xrp_fr)
OI: $(cat $TMPDIR/xrp_oi)

=== 账户信息 ===
余额: $(cat $TMPDIR/balance)
当前持仓: $(cat $TMPDIR/positions)
PROMPT
)

rm -rf "$TMPDIR"

# ── 调用 Claude 执行策略（只做分析+决策+下单，跳过数据采集）──────────────
cd /Users/bytedance/Documents/claude/okx && \
  /Users/bytedance/.local/bin/claude -p "/trisignal-trader

$PROMPT" >> "$LOG_FILE" 2>&1

EXIT_CODE=$?
echo "[$(date)] Done (exit=$EXIT_CODE)." >> "$LOG_FILE"

osascript -e 'display notification "TriSignal 跑完啦～ 快来看结果！" with title "OKX Trading Bot" sound name "Blow"' 2>/dev/null || true
