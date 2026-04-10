---
name: trisignal-trader
version: 4.1.0
description: "TriSignal Trader：4h 周期 BTC/ETH/SOL/XRP 四选一多信号融合策略，评分制决策，自动下单止损止盈，live 模式实盘，支持 daily review。"
triggers:
  - "/trisignal-trader"
  - "trisignal"
  - "TriSignal"
  - "三选一策略"
  - "多信号策略"
  - "4h策略"
compatibility:
  tools:
    - market_get_candles
    - market_get_indicator
    - market_get_funding_rate
    - market_get_open_interest
    - account_get_balance
    - account_get_positions
    - swap_set_leverage
    - swap_place_order
    - swap_place_algo_order
---

# TriSignal Trader — 多信号融合 AI 选标的策略 V4.0

## 目标

在固定 `4h` 周期下，对 `BTC-USDT-SWAP`、`ETH-USDT-SWAP`、`SOL-USDT-SWAP`、`XRP-USDT-SWAP` 四个永续合约进行横向评分比较，选出趋势结构最清晰、风险收益比最合理的唯一候选标的，输出且仅输出：

- `开仓`
- `观望`
- `跳过`

结果为 `开仓` 时执行下单并立即设置止损。默认 `paper mode` 模拟盘运行，保留完整记录支持每日复盘与参数优化。

---

## 固定规则（不可修改）

以下约束不参与 daily review 自动修改，模型不得自行更改：

1. 策略每 `4 小时` 执行一次
2. 分析标的固定：`BTC-USDT-SWAP`、`ETH-USDT-SWAP`、`SOL-USDT-SWAP`、`XRP-USDT-SWAP`
3. 每轮最终状态只能是：`开仓` / `观望` / `跳过`
4. 下单必须使用 `ordType = "market"`
5. 每次下单必须显式携带 `tag = "agentTradeKit"`
6. 开仓成功后必须立即设置止损
7. 单笔最大风险不超过账户净值 `3%`
8. 当日净值回撤超 `8%` 停止新开仓
9. 最多同时持有 `2` 个标的
10. 禁止对冲持仓

## 可调参数（允许 daily review 建议调整）

- 评分阈值与各维度权重
- funding 拥挤阈值
- ATR 过滤阈值
- 第一名与第二名分差阈值
- 标的惩罚因子
- 事件面冲突惩罚强度
- 仓位上限与过滤细节

---

## Execution Mode

| 模式 | 说明 |
|------|------|
| `paper` | 完整执行分析、评分、决策、仓位计算、理论下单止损、记录输出；主要目标是记录与验证 |
| `shadow` | 完整运行策略逻辑，生成完整参数与记录，不提交影响真实资产的订单 |
| `live`（默认） | 正式实盘，任一关键校验失败则放弃下单 |

**模式切换原则**：默认 `live`，daily review 不得自动切换模式。

---

## 执行流程（按顺序，不跳步）

```
Step 1  → 数据采集（4h K线 + 指标计算）
Step 2  → 市场情绪与事件面采集（funding / OI / 外部事件）
Step 3  → 三标的评分（7 个维度）
Step 4  → 趋势判断
Step 5  → 拥挤度过滤
Step 6  → ATR 过滤
Step 7  → 仓位计算
Step 8  → 最终决策
Step 9  → 下单（仅 开仓 时执行）
Step 10 → 止损设置（紧跟开仓）
Step 11 → 记录 decision snapshot
Step 12 → 记录 trade record（仅 开仓 时）
Step 13 → 汇入 daily review 体系
```

---

## Step 1：数据采集

### 指标接口（直接调用，无需手动计算）

每个标的并行调用以下三条命令：

```
okx market indicator ma   <instId> --bar 4H --params 5,10,20,60 --limit 1
okx market indicator macd <instId> --bar 4H --limit 1
okx market indicator atr  <instId> --bar 4H --params 14 --limit 1
```

- `ma` 返回：MA5 / MA10 / MA20 / MA60
- `macd` 返回：DIF / DEA / Histogram（即 macd 字段）
- `atr` 返回：ATR(14)

**不需要拉取原始 K 线，不需要手动计算任何指标。**

### 单标异常处理

若某标的出现以下任一情况，跳过该标的但继续其他标的流程，并记录标的名称、失败步骤、失败原因：

- 接口调用失败 / 返回为空 / 指标值异常

若四个标的全部不可用 → 本轮直接输出 `跳过`，记录"全部标的数据不可用"。

---

## Step 2：市场情绪与事件面采集

```
market_get_funding_rate(instId="BTC-USDT-SWAP")
market_get_funding_rate(instId="ETH-USDT-SWAP")
market_get_funding_rate(instId="SOL-USDT-SWAP")
market_get_funding_rate(instId="XRP-USDT-SWAP")
market_get_open_interest(instType="SWAP", instId="BTC-USDT-SWAP")
market_get_open_interest(instType="SWAP", instId="ETH-USDT-SWAP")
market_get_open_interest(instType="SWAP", instId="SOL-USDT-SWAP")
market_get_open_interest(instType="SWAP", instId="XRP-USDT-SWAP")
```

**事件面**：参考外部热点事件，仅作辅助，不得单独作为开仓依据。

**异常处理**：
- funding / OI 失败 → 记录原因，保留该标的但降低信号可信度
- 事件面缺失 → 标记"事件面缺失"，不中断流程

---

## Step 3：评分制决策框架

对 BTC / ETH / SOL 分别评分，必须输出每个标的的评分说明。

### 评分维度（7 项）

| # | 维度 | 加分条件 | 降分条件 |
|---|------|---------|---------|
| 1 | 缠论均线结构 | MA5>MA10>MA20>MA60 顺排发散 | 均线缠绕、频繁交叉 |
| 2 | MACD 共振 | DIF/DEA/Hist 方向一致 | 零轴附近反复纠缠 |
| 3 | 价格结构延续性 | 多头高低点抬高；空头高低点降低 | 结构破坏、反复穿越 MA20 |
| 4 | OI 配合度 | 价格方向与 OI 变化一致 | 明显背离 |
| 5 | funding 拥挤度 | 费率接近 0，无拥挤 | \|funding\| > 0.1% 降分；拥挤+OI 快速放大显著降分 |
| 6 | ATR 合理性 | ATR 与趋势阶段匹配 | ATR 明显过高（风险大）或过低（机会不足） |
| 7 | 事件面一致性 | 事件面与技术方向一致 | 事件面明显冲突 |

### 评分原则

- 每个标的必须输出评分说明，说明高分或低分原因
- 第一名与第二名差距过小 → 倾向 `观望`
- 所有标的评分都不够高 → 倾向 `跳过`

---

## Step 4：趋势判断原则

### 多头结构特征（越多越高分）

- `MA5 > MA10 > MA20 > MA60`
- 收盘价在 MA20 上方
- 均线发散
- `DIF > DEA`，`Histogram > 0` 且强势
- 高点抬高、低点抬高
- OI 随价格上涨增加

### 空头结构特征（越多越高分）

- `MA5 < MA10 < MA20 < MA60`
- 收盘价在 MA20 下方
- 均线发散
- `DIF < DEA`，`Histogram < 0` 且弱势
- 高点降低、低点降低
- OI 随价格下跌增加

### 趋势不清晰（降分或排除）

- 均线频繁交叉 / 明显缠绕
- 价格反复穿越 MA20
- MACD 零轴附近反复纠缠
- OI 与价格明显背离
- 事件面与技术面明显冲突

---

## Step 5：拥挤度过滤

- `|funding_rate| > 0.1%` → 降级处理
- 轻度拥挤：保留候选资格，降低评分
- 明显拥挤且 OI 同步快速放大 → 优先输出 `观望` 或 `跳过`

---

## Step 6：ATR 过滤

- ATR 明显高于近期正常水平 → 波动过大，降分
- ATR 明显低于近期正常水平 → 机会不足，降分
- 若无法解释 ATR 为何合理 → 不得输出 `开仓`

---

## Step 7：仓位计算

```
账户可承受风险额 = 账户净值 × 3%
止损价（多头）  = 开仓价 × 0.98
止盈价（多头）  = 开仓价 × 1.04
止损价（空头）  = 开仓价 × 1.02
止盈价（空头）  = 开仓价 × 0.96
单位风险        = |开仓价 - 止损价|
sz              = 账户可承受风险额 / 单位风险

所需保证金      = sz × ctVal × 开仓价 / 杠杆（3x）
保证金上限      = 账户净值 × 30%

若所需保证金 > 保证金上限：
  sz = floor(保证金上限 × 杠杆 / (ctVal × 开仓价))
```

**获取账户净值**：
```
account_get_balance(ccy="USDT")
```

**校验**：以下任一情况不得开仓：
- 无法获取账户净值
- 单位风险 ≤ 0
- sz 不是有效数值
- sz 小于最小下单要求
- sz 超过策略允许上限且无法安全截断

**必须记录**：账户净值、风险额、开仓价、止损价、止盈价、单位风险、计算出的 sz、所需保证金、是否触发保证金上限截断

---

## Step 8：最终决策规则

### 开仓条件（全部满足才允许）

1. 存在唯一最优标的
2. 评分显著领先其他标的
3. 趋势结构清晰
4. funding 未出现明显极端拥挤
5. ATR 合理
6. 风控未触发
7. sz 计算有效
8. 当前执行模式允许进入下单流程

### 观望条件

- 有相对较优标的，但评分优势不够大
- 趋势存在但结构不够完整
- funding / OI 显示拥挤风险
- ATR 在边界区间
- 事件面存在冲突

### 跳过条件

- 无清晰候选标的
- 数据不足 / 接口异常
- 风控规则触发
- sz 无法计算
- 当前市场无高确定性机会

---

## Step 9：下单规则

仅当最终结果为 `开仓` 时执行。

```python
swap_place_order(
  instId="<选定标的>",
  tdMode="isolated",
  side="buy",          # 做多；做空用 "sell"
  posSide="long",      # 做空用 "short"
  ordType="market",
  sz="<计算出的 sz>",
  tgtCcy="base_ccy",
  tag="agentTradeKit"
)
```

**强制约束**：`tag = "agentTradeKit"` 缺失则视为参数不合法，不允许提交订单。

**下单前设置杠杆**：
```
swap_set_leverage(instId="<选定标的>", lever="3", mgnMode="isolated")
```

**下单前检查持仓**：
```
account_get_positions(instType="SWAP")
```

持仓检查逻辑（按顺序）：
1. 该标的已有同方向仓位（pos > 0）→ 跳过，不重复开仓
2. 该标的有挂单未成交的 algo 止损止盈单，但仓位为 0 → 说明仓位已平，algo 单为残留，**可以重新开仓**（残留 algo 单会在开仓后被新 OCO 覆盖或手动清理）
3. 当前持仓数 ≥ 2 → 跳过（触发风控规则 9）
4. 有反方向仓位（对冲）→ 跳过（触发风控规则 10）

---

## Step 10：止损与止盈规则

止损价与止盈价计算：

```
止损价（多头）= 开仓价 × 0.98
止盈价（多头）= 开仓价 × 1.04
止损价（空头）= 开仓价 × 1.02
止盈价（空头）= 开仓价 × 0.96
```

盈亏比固定为 2:1。

开仓成功后立即执行（止损 + 止盈合并为一条 OCO 委托）：

```python
swap_place_algo_order(
  instId="<选定标的>",
  tdMode="isolated",
  side="sell",           # 平多；平空用 "buy"
  posSide="long",        # 平空用 "short"
  ordType="oco",
  sz="<同开仓 sz>",
  tgtCcy="base_ccy",
  slTriggerPx="<止损价>",
  slOrdPx="-1",
  tpTriggerPx="<止盈价>",
  tpOrdPx="-1"
)
```

- 止损与止盈不得省略
- 设置失败 → 必须报警并写入记录，不得静默忽略
- 止盈触发后视为本轮交易完成，记录实现盈亏

---

## 交易记录要求

### 记录存储规则

所有记录必须写入 `~/.claude/skills/trisignal-trader/records/` 目录下的 JSON 文件：

- **Decision Snapshot**：每轮必须写入，文件名 `snapshot_YYYYMMDD_HHMM.json`
- **Trade Record**：仅开仓时写入，文件名 `trade_YYYYMMDD_HHMM.json`
- **Daily Summary**：每日汇总，文件名 `daily_YYYYMMDD.json`，每轮执行后追加更新

若写入失败 → 在日志中输出完整 JSON 内容，并标注"⚠️ 文件写入失败，请手动保存"，不得静默忽略。

### Decision Snapshot（每轮必须记录）

```json
{
  "ts": "<ISO8601时间>",
  "mode": "live",
  "bar": "4h",
  "assets": ["BTC-USDT-SWAP", "ETH-USDT-SWAP", "SOL-USDT-SWAP", "XRP-USDT-SWAP"],
  "skipped": [],
  "scores": {
    "BTC": { "score": 0, "reason": "" },
    "ETH": { "score": 0, "reason": "" },
    "SOL": { "score": 0, "reason": "" },
    "XRP": { "score": 0, "reason": "" }
  },
  "indicators": {
    "BTC": { "ma5": 0, "ma10": 0, "ma20": 0, "ma60": 0, "dif": 0, "dea": 0, "hist": 0, "atr": 0, "funding": 0, "oi": 0 },
    "ETH": {},
    "SOL": {},
    "XRP": {}
  },
  "best": "",
  "direction": "",
  "decision": "开仓 | 观望 | 跳过",
  "risk_check": {
    "funding_crowded": false,
    "atr_filtered": false,
    "account_risk": false,
    "margin_capped": false
  },
  "anomalies": ""
}
```

### Trade Record（仅开仓时记录）

```json
{
  "ts": "<ISO8601时间>",
  "instId": "",
  "direction": "long | short",
  "entry_px": 0,
  "sl_px": 0,
  "tp_px": 0,
  "sz": 0,
  "margin_used": 0,
  "risk_amt": 0,
  "ordType": "market",
  "tag": "agentTradeKit",
  "order_id": "",
  "algo_id": "",
  "sl_tp_status": "ok | failed",
  "mode": "live"
}
```

---

## Daily Review

### 目标

按天汇总记录，检查策略行为稳定性，为参数优化提供依据。

### 关注内容

- 当日总轮次
- 开仓 / 观望 / 跳过分布
- BTC / ETH / SOL 被选中情况
- 高分与低分决策表现
- funding 过热场景表现
- ATR 异常场景表现
- 数据失败次数 / 止损失败次数 / tag 缺失次数 / sz 计算失败次数

### Daily Review 边界

**只允许**：总结表现、标记异常、提出参数建议、指出可疑模式

**不允许自动修改**以下硬约束：
- 4h 执行频率
- 标的固定为 BTC/ETH/SOL/XRP
- 最终状态只能为开仓/观望/跳过
- `ordType = "market"`
- `tag = "agentTradeKit"`
- 开仓后立刻设置止损
- 单笔风险不超过净值 3%
- 当日净值回撤超 8% 停止新开仓
- 最多同时持有 2 个标的
- 禁止对冲持仓

---

## 异常处理总则

| 异常类型 | 处理方式 |
|---------|---------|
| 单标数据失败 | 跳过该标，继续其他标的，记录原因 |
| funding/OI 失败 | 降低该标可信度，不中断流程 |
| 事件面缺失 | 标记"事件面缺失"，不中断流程 |
| 账户净值缺失 | 不得开仓，本轮改为 `跳过` |
| sz 计算失败 | 不得开仓，本轮改为 `跳过` |
| 止损失败 | 必须报警、记录、在最终输出中显式披露 |
| 全部关键数据失败 | 直接输出 `跳过` |

---

## 风控规则

下单前必须确认全部满足：

1. 单笔最大风险 ≤ 账户净值 3%
2. 当日净值回撤 < 8%
3. 当前持仓数 < 2
4. 无对冲持仓

任一不满足 → 不允许下单，最终结果改为 `跳过`，必须说明触发了哪条规则。

---

## 输出格式

```
═══════════════════════════════════════════════════
  TriSignal Trader V4.0  [时间]  [执行模式]
═══════════════════════════════════════════════════

【执行概览】
执行时间：
执行模式：paper / shadow / live
分析周期：4h
可用标的：
跳过标的及原因：

【评分结果】
BTC：X/10 — [评分理由]
ETH：X/10 — [评分理由]
SOL：X/10 — [评分理由]

【最优标的判断】
最优标的：
方向：做多 / 做空 / 无
最终决策：开仓 / 观望 / 跳过

【核心依据】
均线结构：
MACD：
价格结构：
OI：
funding：
ATR：
事件面：

【仓位计算】
账户净值：
风险额：
预期开仓价：
止损价：
单位风险：
计算出的 sz：

【风控结论】
满足开仓条件：是 / 否
触发 funding 拥挤：是 / 否
触发 ATR 过滤：是 / 否
触发账户级风控：是 / 否

【执行结果】
（开仓时）
  下单标的：
  下单方向：
  ordType：market
  tag：agentTradeKit
  sz：
  下单结果：
  止损价格：
  止盈价格：
  止损止盈状态：

（观望/跳过时）
  不执行原因：

═══════════════════════════════════════════════════
```

---

## 执行风格要求

- 优先保证稳定性与一致性，不要强行交易
- 默认以 `paper mode` 为第一优先级
- 信号不足时宁可 `观望` 或 `跳过`
- 不要为提高出手率而弱化风控
- 不要遗漏 `tag = "agentTradeKit"`
- 不要在未满足条件时调用下单流程
- 不要让 daily review 自动改写硬约束
- 每一轮都必须留下可复盘记录
