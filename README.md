# TriSignal Trader

**多信号融合 AI 选标的策略 V4.1** — 基于 Claude Code Skill 系统，在 4h 周期下对 BTC/ETH/SOL/XRP 四个永续合约进行横向评分，自动选标的、下单、设置止损止盈。

---

## 功能概览

- **4 标的横向评分**：BTC / ETH / SOL / XRP 永续合约，7 个维度打分，选出唯一最优标的
- **自动下单**：market 单，isolated 3x 杠杆，tag `agentTradeKit`
- **OCO 止损止盈**：多头 SL -2% / TP +4%，空头 SL +2% / TP -4%，盈亏比 2:1
- **风控内置**：单笔风险 ≤ 净值 3%，保证金上限 30%，最多 2 个持仓，禁止对冲
- **每 4 小时自动执行**：通过 macOS launchd 调度，睡眠唤醒后补跑
- **完整记录**：每轮 Decision Snapshot + Trade Record 写入 JSON，支持 daily review

---

## 目录结构

```
trisignal-trader/
├── SKILL.md              # 策略核心：规则、评分框架、执行流程、输出格式
├── run_trisignal.sh      # launchd 触发脚本，调用 Claude Code CLI
├── com.trisignal.trader.plist  # macOS launchd agent 配置
├── logs/                 # 每次执行的原始日志
└── records/              # Decision Snapshot & Trade Record JSON（运行后生成）
```

---

## 依赖

| 依赖 | 说明 |
|------|------|
| [Claude Code CLI](https://claude.ai/code) | `claude` 命令，执行 skill |
| [okx-trade-cli](https://www.npmjs.com/package/@okx_ai/okx-trade-cli) | `npm install -g @okx_ai/okx-trade-cli` |
| OKX API 凭证 | 配置于 `~/.okx/config.toml`，profile 名 `live` |

---

## 快速开始

### 1. 安装依赖

```bash
npm install -g @okx_ai/okx-trade-cli
okx config init   # 配置 API Key / Secret / Passphrase
```

### 2. 手动触发一次

```bash
claude -p "/trisignal-trader"
```

### 3. 配置自动调度（macOS launchd）

```bash
# 复制 plist 到 LaunchAgents
cp com.trisignal.trader.plist ~/Library/LaunchAgents/

# 加载（开机自启 + 立即生效）
launchctl load ~/Library/LaunchAgents/com.trisignal.trader.plist
```

调度时间（北京时间）：03:07 / 07:07 / 11:07 / 15:07 / 19:07 / 23:07

---

## 策略逻辑

```
Step 1  数据采集        → indicator API 获取 MA/MACD/ATR（4H）
Step 2  情绪采集        → funding rate + open interest
Step 3  7 维度评分      → 均线结构 / MACD / 价格结构 / OI / funding / ATR / 事件面
Step 4  趋势判断
Step 5  拥挤度过滤      → |funding| > 0.1% 降分
Step 6  ATR 过滤
Step 7  仓位计算        → 风险额 3% + 保证金上限 30%
Step 8  最终决策        → 开仓 / 观望 / 跳过
Step 9  下单            → market + tag=agentTradeKit
Step 10 OCO 止损止盈
Step 11 写 Decision Snapshot JSON
Step 12 写 Trade Record JSON（仅开仓）
Step 13 汇入 daily review
```

详细规则见 [SKILL.md](./SKILL.md)。

---

## 风控规则（硬约束，不可修改）

1. 单笔最大风险 ≤ 账户净值 3%
2. 当日净值回撤超 8% 停止新开仓
3. 最多同时持有 2 个标的
4. 禁止对冲持仓
5. 所需保证金 ≤ 账户净值 30%

---

## 记录格式

每轮执行后写入 `records/` 目录：

- `snapshot_YYYYMMDD_HHMM.json` — 每轮决策快照（评分、指标、风控结论）
- `trade_YYYYMMDD_HHMM.json` — 开仓记录（仅开仓时写入）
- `daily_YYYYMMDD.json` — 当日汇总

---

## 免责声明

本项目仅供学习与研究使用，不构成任何投资建议。加密货币交易存在极高风险，请自行评估并承担相应风险。
