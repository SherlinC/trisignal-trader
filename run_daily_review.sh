#!/bin/bash
# TriSignal Daily Review — 每日复盘 + 参数优化建议
# 用法：bash run_daily_review.sh [YYYY-MM-DD]
# 默认复盘昨天的记录；传参数可指定日期

source /Users/bytedance/.zshrc 2>/dev/null || true
export PATH="/Users/bytedance/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

SKILL_DIR="/Users/bytedance/.claude/skills/trisignal-trader"
RECORDS_DIR="$SKILL_DIR/records"
REVIEWS_DIR="$SKILL_DIR/reviews"
LOG_DIR="$SKILL_DIR/logs"
mkdir -p "$REVIEWS_DIR" "$LOG_DIR"

# ── 防并发锁 ────────────────────────────────────────────────────────────────
LOCK_FILE="$LOG_DIR/daily_review.lock"
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
    echo "[$(date)] [run_lock] Daily review already running. Skipping."
    exit 0
fi

# ── 确定复盘日期 ─────────────────────────────────────────────────────────────
if [ -n "$1" ]; then
    REVIEW_DATE="$1"
else
    # 默认复盘昨天（UTC+8）
    REVIEW_DATE=$(date -v-1d +"%Y-%m-%d" 2>/dev/null || date -d "yesterday" +"%Y-%m-%d")
fi

DATE_TAG=$(echo "$REVIEW_DATE" | tr -d '-')  # 20260411
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/daily_review_${TIMESTAMP}.log"
REVIEW_OUTPUT="$REVIEWS_DIR/review_${DATE_TAG}.md"

echo "[$(date)] Starting Daily Review for $REVIEW_DATE..." >> "$LOG_FILE"

# ── 收集当日 snapshot 记录 ────────────────────────────────────────────────────
SNAPSHOTS=""
SNAPSHOT_COUNT=0
for f in "$RECORDS_DIR"/snapshot_${DATE_TAG}_*.json; do
    [ -f "$f" ] || continue
    SNAPSHOTS="${SNAPSHOTS}
### $(basename $f)
\`\`\`json
$(cat "$f")
\`\`\`
"
    SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))
done

# ── 收集当日 trade 记录 ───────────────────────────────────────────────────────
TRADES=""
TRADE_COUNT=0
for f in "$RECORDS_DIR"/trade_${DATE_TAG}_*.json; do
    [ -f "$f" ] || continue
    TRADES="${TRADES}
### $(basename $f)
\`\`\`json
$(cat "$f")
\`\`\`
"
    TRADE_COUNT=$((TRADE_COUNT + 1))
done

# ── 收集历史 review（最近7天，用于趋势对比）────────────────────────────────────
PAST_REVIEWS=""
for f in $(ls -t "$REVIEWS_DIR"/review_*.md 2>/dev/null | head -7); do
    [ -f "$f" ] || continue
    PAST_REVIEWS="${PAST_REVIEWS}
---（$(basename $f)）---
$(head -60 "$f")
"
done

# ── 无记录则退出 ───────────────────────────────────────────────────────────────
if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
    echo "[$(date)] No snapshots found for $REVIEW_DATE. Skipping review." >> "$LOG_FILE"
    echo "# Daily Review $REVIEW_DATE — 无记录" > "$REVIEW_OUTPUT"
    echo "当日无 snapshot 记录，跳过复盘。" >> "$REVIEW_OUTPUT"
    exit 0
fi

# ── 获取当前持仓 ───────────────────────────────────────────────────────────────
CURRENT_POSITIONS=$(okx --profile okx-live swap positions 2>&1 || echo "UNAVAILABLE")
CURRENT_BALANCE=$(okx --profile okx-live account balance USDT 2>&1 || echo "UNAVAILABLE")

# ── 构建 Review Prompt ────────────────────────────────────────────────────────
PROMPT=$(cat <<PROMPT
你是 TriSignal Trader 的策略分析师，请对 **${REVIEW_DATE}** 的所有交易记录进行严格的每日复盘。

## 复盘目标
1. 客观评估当日所有决策质量（不护短，发现真实问题）
2. 统计执行纪律（风控执行、格式合规、数据完整性）
3. 提出具体可落地的参数优化建议（必须有数据依据，不得泛泛而谈）
4. 输出 SKILL.md 可调参数的建议修改值（如有）

## 当日数据（共 ${SNAPSHOT_COUNT} 轮执行，${TRADE_COUNT} 笔开仓）

### Decision Snapshots
${SNAPSHOTS}

### Trade Records
${TRADES:-（当日无开仓记录）}

### 当前持仓状态（复盘时刻）
\`\`\`
${CURRENT_POSITIONS}
\`\`\`

### 当前账户净值
\`\`\`
${CURRENT_BALANCE}
\`\`\`

### 近期历史复盘摘要（用于趋势对比）
${PAST_REVIEWS:-（暂无历史复盘）}

---

## 输出格式（严格按此结构输出，不得省略任何章节）

# Daily Review — ${REVIEW_DATE}

## 执行摘要
- 总轮次：X 轮
- 决策分布：开仓 X / 观望 X / 跳过 X
- 开仓标的：BTC X次 / ETH X次 / SOL X次 / XRP X次
- 最优标的命中率（得分最高的是否最终被选中）：X%

## 评分质量分析
（分析每轮评分是否合理；识别评分异常——如得分与信号明显不符的情况）

## 风控执行检查
- 规则9（2标的上限）：执行 ✅/❌
- 规则10（禁对冲）：执行 ✅/❌
- 止损设置：ok/failed X次
- tag 合规：✅/❌
- Snapshot 提取：成功 X / 失败 X

## 信号质量评估
（分析 MACD hist 数值、MA排列质量、funding 数值的实际分布，判断当前市场阶段是否适合该策略）

## 问题识别
（列出具体问题，要有数据支撑，不得笼统描述）
1. 问题X：[具体描述 + 数据证据]

## 参数优化建议
（只能修改 SKILL.md 中"可调参数"部分，禁止触及硬约束）

| 参数名 | 当前值 | 建议值 | 依据 |
|--------|--------|--------|------|
| 评分开仓阈值 | 8.0 | ? | [数据依据] |
| 1/2名差距阈值 | 1.5 | ? | [数据依据] |
| MACD 权重 | ×2 | ? | [数据依据] |
| ... | ... | ... | ... |

若参数不需要调整，明确写"建议维持当前值，原因：..."

## 下一轮执行建议
（针对下一个 4H bar 的具体关注点，≤5条，每条≤20字）

## 综合评级
本日策略表现：⭐⭐⭐⭐⭐（1-5星）
核心问题一句话：

PROMPT
)

# ── 调用 Claude 执行复盘 ───────────────────────────────────────────────────────
echo "[$(date)] Calling Claude for daily review..." >> "$LOG_FILE"

TMPDIR_OUT=$(mktemp -d)
CLAUDE_OUTPUT="$TMPDIR_OUT/review_output"

cd /Users/bytedance/Documents/claude/okx && \
  /Users/bytedance/.local/bin/claude -p "$PROMPT" 2>&1 | tee -a "$LOG_FILE" > "$CLAUDE_OUTPUT"

EXIT_CODE=${PIPESTATUS[0]}

# ── 保存 Review 输出 ───────────────────────────────────────────────────────────
if [ -s "$CLAUDE_OUTPUT" ]; then
    cat "$CLAUDE_OUTPUT" > "$REVIEW_OUTPUT"
    echo "" >> "$REVIEW_OUTPUT"
    echo "---" >> "$REVIEW_OUTPUT"
    echo "*Generated: $(date)*" >> "$REVIEW_OUTPUT"
    echo "[$(date)] Review saved: $(basename $REVIEW_OUTPUT)" >> "$LOG_FILE"
else
    echo "[$(date)] WARNING: Claude returned empty output" >> "$LOG_FILE"
fi

rm -rf "$TMPDIR_OUT"

# ── 提取参数建议（%%PARAMS_BEGIN%% 标记，供未来自动应用）────────────────────────
PARAMS_JSON=$(awk '/^%%PARAMS_BEGIN%%/{found=1; next} /^%%PARAMS_END%%/{found=0} found{print}' "$REVIEW_OUTPUT")
if [ -n "$PARAMS_JSON" ]; then
    echo "$PARAMS_JSON" > "$REVIEWS_DIR/params_suggestion_${DATE_TAG}.json"
    echo "[$(date)] Params suggestion saved." >> "$LOG_FILE"
fi

echo "[$(date)] Daily review complete (exit=$EXIT_CODE)." >> "$LOG_FILE"

# ── macOS 通知 ─────────────────────────────────────────────────────────────────
osascript -e "display notification \"每日复盘完成：${REVIEW_DATE}\" with title \"TriSignal Review\" sound name \"Glass\"" 2>/dev/null || true

echo ""
echo "✅ 复盘完成：$REVIEW_OUTPUT"
