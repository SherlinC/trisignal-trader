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

> **预计执行时间：3~5 分钟**（数据采集 ~1min，评分决策 ~1min，下单+OCO ~1min，记录写入 ~30s）

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
7. 单笔最大风险不超过账户净值 `6%`
8. 当日净值回撤超 `8%` 停止新开仓
9. 最多同时持有 `2` 个**不同标的**（同一标的可同方向加仓，不限次数）
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

### 指标完整性校验（数据采集完成后必须执行）

进入 Step 3 评分前，对每个标的执行以下校验：

**必须字段**（任一为 null / 缺失 / 0 → 该标的降级处理）：
- MA5、MA10、MA20、MA60
- DIF、DEA、Histogram
- ATR(14)

**降级规则**：
- 缺失 1 个必须字段 → 该维度评分强制设为 3 分（中性偏低），并在评分说明中标注"[数据缺失]"
- 缺失 2 个及以上必须字段 → 该标的整体评分上限为 5 分，不得开仓
- MA5/MA10/MA20/MA60 任一缺失 → 均线结构维度强制 0 分
- DIF/DEA/Hist 任一缺失 → MACD 维度强制 0 分
- ATR 缺失 → ATR 维度强制 0 分，且不得输出 `开仓`

**记录要求**：每个标的的数据完整性状态必须写入 snapshot 的 `indicators` 字段，null 值保留原样不得填充估算值。

---

## Step 2：市场情绪与事件面采集

```
okx market funding-rate BTC-USDT-SWAP
okx market funding-rate ETH-USDT-SWAP
okx market funding-rate SOL-USDT-SWAP
okx market funding-rate XRP-USDT-SWAP
okx market open-interest --instType SWAP --instId BTC-USDT-SWAP
okx market open-interest --instType SWAP --instId ETH-USDT-SWAP
okx market open-interest --instType SWAP --instId SOL-USDT-SWAP
okx market open-interest --instType SWAP --instId XRP-USDT-SWAP
```

**事件面**：参考外部热点事件，仅作辅助，不得单独作为开仓依据。

**异常处理**：
- funding / OI 失败 → 记录原因，保留该标的但降低信号可信度
- 事件面缺失 → 标记"事件面缺失"，不中断流程

---

## Step 3：评分制决策框架

对 BTC / ETH / SOL 分别评分，必须输出每个标的的评分说明。

### 评分维度（7 项，MACD 双倍权重）

| # | 维度 | 权重 | 加分条件 | 降分条件 |
|---|------|------|---------|---------|
| 1 | 缠论均线结构 | ×1 | MA5>MA10>MA20>MA60 顺排发散 | 均线缠绕、频繁交叉 |
| 2 | **MACD 共振** | **×2** | DIF/DEA/Hist 方向一致，金叉有效 | 零轴附近反复纠缠，死叉 |
| 3 | 价格结构延续性 | ×1 | 多头高低点抬高；空头高低点降低 | 结构破坏、反复穿越 MA20 |
| 4 | OI 配合度 | ×1 | 价格方向与 OI 变化一致 | 明显背离 |
| 5 | funding 拥挤度 | ×1 | 费率接近 0，无拥挤 | \|funding\| > 0.1% 降分；拥挤+OI 快速放大显著降分 |
| 6 | ATR 合理性 | ×1 | ATR 与趋势阶段匹配 | ATR 明显过高（风险大）或过低（机会不足） |
| 7 | 事件面一致性 | ×1 | 事件面底色 bullish 且与技术方向一致 | 事件面 bearish 或与技术方向冲突；宏观面 bearish 全标的 -1 |

**加权评分公式**：`总分 = (MA + MACD×2 + 结构 + OI + Funding + ATR + 事件) / 8`

> MACD 是趋势动能的核心信号，金叉/死叉对方向预测力最强，故赋予双倍权重。每个维度满分 10 分，总分最高 10 分。

### Dimension 7 评分规则（事件面一致性）

数据来源：`event_context.txt`（由 Daily Review 每日凌晨生成，基于 Chainbase Twitter/X 社交数据）

| 底色 | 与技术方向关系 | 分值 |
|------|--------------|------|
| bullish + 技术面多头 | 共振 | 7-9 |
| bullish + 技术面空头 | 冲突 | 3-4 |
| neutral | 无论技术方向 | 5 |
| bearish + 技术面空头 | 共振 | 7-9 |
| bearish + 技术面多头 | 冲突 | 2-4 |
| MACRO bearish | 全标的额外 -1 | — |
| 数据缺失 | — | 5（标记"事件面缺失"）|

### 评分原则

- **输出格式严格限制**：每个标的仅输出一行评分摘要，格式为 `标的：X/10 — 关键原因（≤25字）`，**禁止输出详细分析表格**
- 最优标的评分 < 8 分 → 直接输出 `观望`，不进入开仓流程
- 第一名与第二名差距 < 1.5 分 → 倾向 `观望`
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

### 止损价计算（结构化 + ATR 双重验证）

```
ATR = ATR(14)，来自 Step 1 已采集数据

结构止损（多头）= 最近 3 根 4H K 线的最低 low（swing low）
结构止损（空头）= 最近 3 根 4H K 线的最高 high（swing high）

结构距离 = |开仓价 - 结构止损|
结构距离百分比 = 结构距离 / 开仓价

验证规则：
  若 结构距离 < 0.5 × ATR  → 结构位太近，改用 1.5 × ATR 作为止损距离
  若 结构距离 > 2.5 × ATR  → 结构位太远，截断为 2.0 × ATR 作为止损距离
  否则                      → 使用结构止损

止损价（多头）= 开仓价 - 最终止损距离
止损价（空头）= 开仓价 + 最终止损距离
止盈价（多头）= 开仓价 + 最终止损距离 × 2   （盈亏比固定 2:1）
止盈价（空头）= 开仓价 - 最终止损距离 × 2
```

**必须记录**：`sl_method`（structure / atr_min / atr_max）、`swing_low/high`、`atr_at_entry`、`sl_distance`、`sl_distance_pct`

### 仓位计算

```
账户可承受风险额 = 账户净值 × 6%
单位风险        = 最终止损距离
sz              = 账户可承受风险额 / 单位风险

所需保证金      = sz × ctVal × 开仓价 / 杠杆（5x）
保证金上限      = 账户净值 × 45%

若所需保证金 > 保证金上限：
  sz = floor(保证金上限 × 杠杆 / (ctVal × 开仓价))
```

**获取账户净值**：
```
okx --profile okx-live account balance USDT
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
2. 最优标的评分 **≥ 8 分**，且显著领先其他标的（差距 ≥ 1.5 分）
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

```bash
okx --profile okx-live swap place \
  --instId <选定标的> \
  --tdMode isolated \
  --side buy \
  --posSide long \
  --ordType market \
  --sz <计算出的 sz> \
  --tag agentTradeKit
```

**强制约束**：`--tag agentTradeKit` 缺失则视为参数不合法，不允许提交订单。

**下单前设置杠杆**：
```bash
okx --profile okx-live swap leverage --instId <选定标的> --lever 5 --mgnMode isolated --posSide long
```

**下单前检查持仓**：
```bash
okx --profile okx-live swap positions
```

持仓检查逻辑（按顺序）：
1. 该标的有**反方向**仓位（对冲）→ 跳过（触发风控规则 10）
2. 该标的有**同方向**仓位（pos > 0）→ **允许加仓**，继续执行下单流程
3. 该标的无仓位，但当前持有的**不同标的数** ≥ 2 → 跳过（新标的超限，触发风控规则 9）
4. 该标的有挂单未成交的 algo 止损止盈单，但仓位为 0 → 说明仓位已平，algo 单为残留，**可以重新开仓**（残留 algo 单会在开仓后被新 OCO 覆盖或手动清理）

> **加仓说明**：同一标的同方向加仓时，仓位合并计算。新 OCO 止损止盈单仅覆盖本次新增的 sz，原有止损止盈单保持不变。加仓的 sz 计算方式与首仓相同（基于账户净值 6% 风险额）。

---

## Step 10：止损与止盈规则

止损价与止盈价计算：

```
止损价 = 开仓价 ± 最终止损距离（由 Step 7 结构化+ATR 双重验证得出）
止盈价 = 开仓价 ± 最终止损距离 × 2（盈亏比固定 2:1）
```

盈亏比固定为 2:1。

开仓成功后立即执行（止损 + 止盈合并为一条 OCO 委托）：

```bash
okx --profile okx-live swap algo place \
  --instId <选定标的> \
  --tdMode isolated \
  --side sell \
  --posSide long \
  --ordType oco \
  --sz <同开仓 sz> \
  --slTriggerPx <止损价> \
  --slOrdPx=-1 \
  --tpTriggerPx <止盈价> \
  --tpOrdPx=-1
```

### 止损OCO 3次重试 + 自动平仓兜底（工程安全）

止损止盈设置完成后，**必须立即验证**是否成功（检查命令是否返回 algoId）。

若第1次失败，按以下流程处理：

```
第1次失败 → 等待 2 秒 → 第2次重试同参数
第2次失败 → 等待 2 秒 → 第3次重试同参数
第3次仍失败 → 【自动平仓兜底】立即执行：
  okx --profile okx-live swap close \
    --instId <刚开仓的标的> \
    --mgnMode isolated \
    --posSide long（或 short）
```

**⚠️ CRITICAL 兜底原则**：止损设置3次全部失败后，**必须平仓**，不得保留裸仓。平仓优先于一切记录操作。

**输出要求**：
- 止损成功：在【执行结果】中写 `止损止盈状态：ok (algoId: xxx)`
- 止损1-2次重试后成功：写 `止损止盈状态：ok (重试X次, algoId: xxx)`
- 止损3次失败 + 平仓触发：写 `止损止盈状态：CRITICAL—3次失败，已执行紧急平仓` 并在 trade record 的 `sl_tp_status` 写 `"failed_auto_closed"`
- 平仓本身失败：写 `止损止盈状态：CRITICAL—3次失败+平仓失败，需人工干预！` 并触发最高级别告警

- 止盈触发后视为本轮交易完成，记录实现盈亏

---

## 交易记录要求

### 记录存储规则

记录由外部 shell 脚本（`run_trisignal.sh`）负责写入文件，Claude 只需在输出末尾打印特殊标记包裹的 JSON，shell 会自动提取并保存。

**Claude 输出格式要求**（每轮执行结束时必须输出，不得省略）：

```
%%SNAPSHOT_BEGIN%%
{ ...完整 snapshot JSON... }
%%SNAPSHOT_END%%
```

开仓时额外输出：

```
%%TRADE_BEGIN%%
{ ...完整 trade JSON... }
%%TRADE_END%%
```

- JSON 必须是合法的单行或多行 JSON，不得包含注释
- 标记行必须单独成行，前后无其他字符
- shell 会自动提取并写入 `records/snapshot_YYYYMMDD_HHMM.json` 和 `records/trade_YYYYMMDD_HHMM.json`
- 若 JSON 格式有误，shell 会在日志中报错，Claude 无需额外处理

### Decision Snapshot（每轮必须记录）

```json
{
  "ts": "<ISO8601时间>",
  "mode": "live",
  "bar": "4h",
  "assets": ["BTC-USDT-SWAP", "ETH-USDT-SWAP", "SOL-USDT-SWAP", "XRP-USDT-SWAP"],
  "skipped": [],
  "scores": {
    "BTC": { "score": 0, "reason": "", "dim": { "ma": 0, "macd": 0, "structure": 0, "oi": 0, "funding": 0, "atr": 0, "event": 0 } },
    "ETH": { "score": 0, "reason": "", "dim": { "ma": 0, "macd": 0, "structure": 0, "oi": 0, "funding": 0, "atr": 0, "event": 0 } },
    "SOL": { "score": 0, "reason": "", "dim": { "ma": 0, "macd": 0, "structure": 0, "oi": 0, "funding": 0, "atr": 0, "event": 0 } },
    "XRP": { "score": 0, "reason": "", "dim": { "ma": 0, "macd": 0, "structure": 0, "oi": 0, "funding": 0, "atr": 0, "event": 0 } }
  },
  "indicators": {
    "BTC": { "ma5": 0, "ma10": 0, "ma20": 0, "ma60": 0, "dif": 0, "dea": 0, "hist": 0, "atr": 0, "funding": 0, "oi": 0 },
    "ETH": { "ma5": 0, "ma10": 0, "ma20": 0, "ma60": 0, "dif": 0, "dea": 0, "hist": 0, "atr": 0, "funding": 0, "oi": 0 },
    "SOL": { "ma5": 0, "ma10": 0, "ma20": 0, "ma60": 0, "dif": 0, "dea": 0, "hist": 0, "atr": 0, "funding": 0, "oi": 0 },
    "XRP": { "ma5": 0, "ma10": 0, "ma20": 0, "ma60": 0, "dif": 0, "dea": 0, "hist": 0, "atr": 0, "funding": 0, "oi": 0 }
  },
  "best": "",
  "direction": "long | short | none",
  "decision": "开仓 | 观望 | 跳过",
  "decision_reason": "",
  "position_plan": {
    "entry_px": 0,
    "swing_ref": 0,
    "sl_method": "structure | atr_min | atr_max",
    "sl_distance": 0,
    "sl_distance_pct": 0,
    "atr_at_entry": 0,
    "sl_px": 0,
    "tp_px": 0,
    "risk_reward": "2:1",
    "account_equity": 0,
    "risk_amt": 0,
    "sz": 0,
    "margin_used": 0,
    "margin_capped": false
  },
  "risk_check": {
    "funding_crowded": false,
    "atr_filtered": false,
    "account_risk": false,
    "margin_capped": false,
    "position_conflict": ""
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
  "sl_method": "structure | atr_min | atr_max",
  "swing_ref": 0,
  "sl_distance": 0,
  "sl_distance_pct": 0,
  "atr_at_entry": 0,
  "risk_reward": "2:1",
  "sz": 0,
  "margin_used": 0,
  "risk_amt": 0,
  "account_equity": 0,
  "margin_capped": false,
  "ordType": "market",
  "tag": "agentTradeKit",
  "order_id": "",
  "algo_id": "",
  "sl_tp_status": "ok | failed",
  "mode": "live",
  "score_at_entry": 0,
  "score_reason": ""
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
- 单笔风险不超过净值 6%
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

1. 单笔最大风险 ≤ 账户净值 6%
2. 当日净值回撤 < 8%
3. 持有的**不同标的数** < 2（同一标的加仓不计入新标的数）
4. 无对冲持仓（同标的反方向禁止）

任一不满足 → 不允许下单，最终结果改为 `跳过`，必须说明触发了哪条规则。

---

## 输出格式

> **Token 预算约束**：总输出必须控制在 4000 tokens 以内。评分分析每个标的仅一行，禁止详细表格，核心依据每项 ≤15 字，snapshot JSON 必须完整输出。

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
