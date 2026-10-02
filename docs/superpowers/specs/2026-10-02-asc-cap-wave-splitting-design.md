# WCL 导出分波：升腾上限拆分规则设计

## 目标

在 `tools/wclplan` 的分波逻辑中新增一条用户确认的规划规则：按每波升腾（Ascendance, spell 114050）次数上限拆分波次——

- **含 boss 的波：升腾上限 2。**
- **纯小怪波：升腾上限 1。**

超过上限时按 MDT 路线 pull 边界拆成多波，使每个子波的升腾数不超过其上限。这是「规划分段」约定，会覆盖「日志确证的连续战斗合并」。

## 背景与现状

当前 `tools/wclplan/waves.js` 的 `buildCombatWaveDetail` 按两级证据分波：

1. **连续战斗段（combatSegments）**：落在同一段的路线 pull 合并为一波（`reason="confirmed-combat"`）。
2. **boss 进战拆分（bossEncounters）**：当 boss 进战前存在升腾、且 boss 战内也有升腾时，把 boss 从其前置小怪中拆出（`reason="boss-entry"`）；boss 死亡后到下一批怪之间强制切断。

现状对**每波升腾次数没有任何上限**：
- `waves.test.js`「Boss内部三次或四次升腾仍属于同一Boss波」明确规定 boss 波内 3–4 次升腾也不拆分。
- 小怪波按连续战斗合并，无论其中有多少次升腾。

唯一的次数约束是 `cli.js` 的 NPT 格式硬上限：任一技能每波 > 5 次即报错（不拆分、不截断）。

本规则**反转**上述「boss 3–4 次升腾算一波」的既有决定，并为小怪波引入上限 1。

## 规则定义

- 波次上限 `cap(wave) = 含 boss pull ? 2 : 1`。
- 「含 boss pull」= 该波的路线 pull 集合里包含任一 `bossEncounters[].pull`（或其 `firstPull..pull` 拖入批次中的 boss pull）。
- 当一波的升腾总数 > `cap` 时，按 pull 边界贪心拆分为多个子波，使每个子波升腾数 ≤ 其自身 `cap`。
- 升腾上限**只约束升腾**；嗜血、药水不参与本规则的拆分判定（仍受 cli 的 >5 硬上限保护）。

## 算法（方案 A：分组后追加再拆分 pass）

在 `buildCombatWaveDetail` 现有「段合并 + boss 进战拆分」产出的波次之上，追加一道再拆分 pass：

1. **升腾归属到 pull**：每条 `skill==="asc"` 的 castEvent，按其施法时间 `t` 落进哪个路线 pull 的 `pullTimings` 窗口 `[start, end]`，就计入该 pull 的 `ascPerPull[pull]`。无 timings 的 pull 视为 0（与现有「缺失时间不臆测」一致）。
2. **逐波贪心再拆分**：对每个波（pull 升序），维护当前子波的累计升腾与「当前子波是否含 boss pull」。顺序尝试把下一个 pull 并入当前子波：
   - 计算并入后的候选子波 `cap`（含 boss→2，否则→1）与累计升腾。
   - 若累计升腾 ≤ `cap`，并入；否则在下一个 pull 前切一刀，开启新子波。
3. **单 pull 超上限（原子不可拆）**：若单个 pull 自身升腾 > 其 `cap`（该 pull 含 boss→2，否则→1），无法在 pull 内部再切，则该 pull 单独成波、允许超限，并产出一条 warning。
4. **窗口重算**：每个（子）波的 `start/end` 取其成员 pull timings 的最小 start / 最大 end；`castStart/castEnd` 沿用现有规则重算——含 boss 的子波保留 `bossStart`/`firstBossAscendance` 语义（`castStart=bossStart`，`castEnd` 受 boss 结束与后波 `castStart` 夹逼），纯小怪子波用其 pull 窗口与段边界。重算后 `castWaves` 对 asc/lust/pot 与 rotationCastEvents 的归属保持自洽。
5. **reason 标注**：再拆分产生的新波 `reason="asc-cap"`；原有 `confirmed-combat`/`boss-entry`/`original` 不变，便于报告区分「日志确证」与「规划拆分」。

## 边界情况

- **boss 常为单个 pull 且战斗长**：一个 boss pull 内 3 次升腾 → 单 pull 超上限 → 保留为一波 + warning（规则第 3 条）。这是常见且预期的结果，不视为错误。
- **混合波（boss + 前置小怪未进战拆分）**：整波按「含 boss」用上限 2；再拆分时，含 boss pull 的子波用 2、被切出的纯小怪子波用 1。
- **纯小怪连续战斗 2 次升腾**：拆成 2 波（各 ≤1 次升腾），即使日志显示为一段连续战斗——这是用户确认的规划约定，`reason="asc-cap"` 明确标注其非日志脱战。
- **升腾恰落在两 pull 边界**：按 `t` 落入的 pull 窗口归属；边界重叠时归较晚的 pull（与现有 `castWaves` 倒序归属一致）。
- **无 pullTimings**：`ascPerPull` 全 0，不触发再拆分（与现有「缺时间不臆测」一致）。

## 与现有 >5 硬上限的关系

升腾经本规则后每波 ≤ 2（或单 pull 告警保留），不再触发 cli 的 >5 报错路径（该路径对升腾实际失效但保留，作为其它技能与异常输入的保护）。pot/lust 不变。

## 测试计划（`tools/wclplan/waves.test.js`、`cli.test.js`）

- **反转**：`waves.test.js`「Boss内部三次或四次升腾仍属于同一Boss波」→ 改为「boss 波升腾 > 2 时按 pull 边界拆成每波 ≤2；单个 boss pull 内 3 次升腾保留一波并告警」。
- 新增：纯小怪单段连续战斗含 2 次升腾 → 拆成 2 波，`reason="asc-cap"`。
- 新增：单个小怪 pull 内 2 次升腾（原子）→ 保留 1 波 + warning。
- 新增：混合波（boss+小怪）上限按含 boss=2 判定；被切出的纯小怪子波按 1 判定。
- 新增：再拆分后 `castWaves` 对 asc/lust/pot 与 rotationCastEvents 归属仍全部命中、无 -1。
- fixture 回归：更新 `fixtures/confirmed-combat.json` 相关断言，锁定新分组与 warning。
- cli 端到端：断言新分组数、routeKey 变化、plan/ratio 行随波数变化。

## 重导影响

波数变化 → 合并后的 pulls 变化 → **routeKey 变化**，`route.mdt.txt` / `importplan-pack.txt` / `importratiopack.txt` / `summary.json` / `report.html` / `wave-plan.csv` 全部重生成。已导出的两份（密谋小径 `Mcdmtnwx4h6CYHNT-f11`、红玉 `CxtJgwnRbAKja36z-f11`）需按新逻辑重导；游戏内需按**新** routeKey 重新导入 MDT 路线 + `/npt importplanpack` + `/npt importratiopack`。

## 不在范围内（YAGNI）

- 不改嗜血/药水的分波规则（本规则只按升腾拆分）。
- 不新增 CLI 参数开关（规则默认生效）；若后续需要可再加 `--asc-cap` 覆盖。
- 不改游戏内 Lua 导入/渲染逻辑（routeKey 与 plan/ratio 语法不变，仅数值随分波变化）。
- 不改死亡对齐、boss 进战拆分、连续战斗段等既有证据规则。
