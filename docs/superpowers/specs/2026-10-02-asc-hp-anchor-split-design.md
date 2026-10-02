# 升腾归属与锚点分波修正 设计文档

**日期：** 2026-10-02
**状态：** 设计已与用户确认，待实现
**关联：** 修订 `2026-10-02-asc-cap-wave-splitting-design.md`（升腾上限分波）的**归属机制**部分；上限规则（boss 2 / 小怪 1）本身不变。

---

## 1. 背景与现象

红玉（`CxtJgwnRbAKja36z` f11）按升腾上限规则导出后，用户指出第 2、5 波「都是很小的一波怪」却各背 2 次升腾，而真正吃升腾的大怪（德拉加尔 / 烈焰之咽）被留在上一波：

- 现 wave2 = 原 pull 3（17 兵力）背 2 升腾 + 原子告警；德拉加尔在 pull 2，却被分进 wave1。
- 现 wave5 = 原 pull 7（14 兵力）背 2 升腾 + 原子告警；烈焰之咽在 pull 6，却被分进 wave4。
- 现 wave9 = 原 pull 14 背 2 升腾 + 告警（Ryvati 恰好就在 pull 14，属巧合命中）。
- 密谋（`Mcdmtnwx4h6CYHNT` f11）现 wave8 = 原 pull 13（4 只 Demon Fly，4 兵力）背 2 升腾 + 告警；真正的大怪包在 pull 12。

## 2. 根因（两个退化，同一个来源）

**根因 A — 时间 Voronoi 退化（`ascCountPerPull`）。** `pullTimings` 里**同一连续战斗段的所有 pull 起始时刻完全相同**（时刻来自战斗段，不是逐 pull 接战）。红玉 pull 1/2/3 都是 10.518，5/6/7 都是 486.397，12/13/14 都是 1185.759。`ascCountPerPull` 取「最后一个 start ≤ 施法时刻的 pull」，于是段内每条升腾都落到**该段最后一个 pull**，与真实目标无关。

**根因 B — 子波共享时间窗（`castWaves`）。** 段内拆出的子波 `start/end` 相同，`computeWaveWindows` 把前一子波 `castEnd` 夹逼成零宽，窗口式 `castWaves` 于是把整段升腾全判给最后一个子波。即便修好根因 A，只要还用窗口归属，升腾仍会堆到最后一波。

## 3. 关键更正：boss 判据是等级 92，不是 MDT `isBoss`

用户更正 + 数据证实：

| 类别 | 等级 | count | MDT `isBoss` | 例 |
|:--|:-:|:-:|:-:|:--|
| 真 boss | **92** | 0 | true | 红玉 Melidrussa/Kokia/Erkhart/Kyrakka；密谋 Xathuux 等 |
| 大精英 | **91** | 25–48 | **不一致** | 红玉 Draghar/Flamegullet/Ryvati/Thunderhead 标 `true`；密谋 Shivan Punisher/Felmaster Lucsei/Defiled Golem 标 `false` |

**结论：** MDT `isBoss` 位不可靠（同为 91 级精英，两个副本标记相反），**禁止用它判 boss**。可靠判据 = 等级 92 ⟺ count=0 ⟺ WCL encounter。现有 `bossPullNumbers(bossEncounters)` 取的就是 WCL encounter = 92 级真 boss，**已正确，不改**。德拉加尔 / 烈焰之咽 / Ryvati 是 91 级大精英 = **小怪**，上限仍为 **1**。

> 撤销上一轮分析里「给大精英 boss 上限 2」的提法——那是基于 `isBoss` 的错误前提。

## 4. 数据局限（必须坦白）

`wcl-events.json` 的 `events` **只有 `casts`，没有逐目标伤害**；段内 pull 起始时刻相同；同种小怪跨多个 pull（如 Deepstone Earthshaper 在 pull 1/2/3 都有），死亡事件的 `instanceId` 也难以稳定映射回具体 pull。**因此日志无法确证「某次升腾属于哪个 pull」**——段内切点只能是规划启发式，不能冒充日志事实。可用信号：MDT 静态 `health`（每 pull 最高血量敌人）、升腾施法时刻、MDT 克隆坐标。

## 5. 设计：HP 锚点分波 + 升腾均分

用户已确认口径：
- **锚点信号** = 段内**最高血量敌人所在的 pull**（「大怪血量非常多」）。
- **升腾分配** = 每子波**均分**（cap 1 时每波 1 个），大精英那一波不独占。

### 5.1 规则

**适用范围：仅纯小怪波（不含 92 级 boss pull，cap 1）。** 含 boss 的波（cap 2）走**现有** `ascCountPerPull`(Voronoi) + `splitWaveByAscCap`(贪心) 路径**不变**——因为 boss 波内各 pull 时刻互异（如 boss 与 firstPull 分属不同接战时刻），Voronoi 归属可靠，且 boss 的升腾天然集中在 boss 本身；对 boss 波做「均分」反而会把开 boss 的升腾错分给进战前小怪。实测数据里 boss 波升腾从不超上限 2，本就不触发拆分。

对每个**纯小怪初始波** W：

1. `A` = W 时间窗内的升腾数（窗口在**段级**可靠，因为段与段不重叠）。
2. `cap` = 1（小怪）。
3. `A ≤ cap` → 不拆。
4. `A > cap` → 需 `k = ceil(A / cap) = A` 个子波：
   - **切点**：在 `W[1..]`（**排除首 pull**，首 pull 前无处可切）中按 `pullMaxHealth` **降序**取前 `k-1` 个 pull 作为切点，升序排列 → 把 W 切成 k 个 pull 组。最高血量大怪因此**起一个新子波**，落在靠后的子波。**血量相同则 pull 号小者优先**（保证确定性；密谋 pull12 的 Shivan Punisher 与 Fel Invoker 同为 5.5M 但在同一 pull，不产生歧义）。
   - **pull 不够**（`|W| < k`）：每个 pull 各自成组；若仍 `A > cap·组数`，保留为原子波并出 warning（沿用现有告警文案与语义）。
   - **升腾分配**：把 A 个升腾按时刻排序，贪心每组填满至 `cap`，分到 k 个子波（cap1 时即每波 1 个）。

### 5.2 子波时间窗（修根因 B）

拆分后**不能让子波共享时间窗**。为每个子波显式设定 `castStart/castEnd`：把段内升腾时刻按 5.1 的分组，在**相邻两组之间取中点**作为时间切点；子波 j 的 `castStart` = 上一时间切点（或段起点），`castEnd` = 下一时间切点（或段终点）。这样现有窗口式 `castWaves` 会把每个升腾判给正确子波，实现均分。`wave.start/end`（用于报告时间轴展示）保持段范围不变，只细分 `castStart/castEnd`。

### 5.3 reason

锚点拆出的子波标 `reason="asc-cap"`（与既有约定一致；切点由 HP 锚点决定，但拆分动因仍是升腾上限）。boss-entry / confirmed-combat 语义不变。

## 6. 数据管线改动

`health` 已在 MDT 副本 Lua 里紧邻 `count`（`["count"]=30, ["health"]=9729765`）。

1. **`align.js` `loadEnemyMeta`**：解析式增加 `health`，`meta[idx] = {id, count, clones, health}`（缺省 0）。
2. **`cli.js`**：在调用 `buildCombatWaveDetail` **之前**用 `loadEnemyMeta` + 路线 pull 计算 `pullMaxHealth[i] = max(该 pull 内各 enemy 的 health)`，作为新入参传入。（`loadEnemyMeta` 调用点从 line 112 前移，或复用同一次解析结果。）
3. **`waves.js` `buildCombatWaveDetail`**：新增可选入参 `pullMaxHealth`（数组，每 pull 一项）。拆分循环按 `hasBoss = wave.pulls.some(p => bossPulls.has(p))` **分支**：
   - **boss 波**：走现有 `ascCountPerPull` + `splitWaveByAscCap`，**完全不变**（保留 line 50 / cli line 148 的 `[5]|[6]`、boss 独占 4 升腾、原子告警行为）。
   - **小怪波**：走新的 HP 锚点拆分——新增纯函数 `anchorCutPoints(pulls, pullMaxHealth, k)`、`distributeAscTimes(ascTimes, k, cap, winStart, winEnd)`、`cutPullsAt(pulls, cutPoints)`；子波 `reason="asc-cap"`，`castStart/castEnd` 用 5.2 的中点子窗显式设定。
   - `ascCountPerPull` 与 `splitWaveByAscCap` **保留**（boss 波仍用）；单 pull 超上限的原子告警路径保留（boss 波）。
4. 缺 `pullMaxHealth` 时（老 fixture / 单元测试）：回退为「无锚点信息」，按 pull 顺序贪心拆（等价旧行为的**顺序**切点），保证既有非锚点用例不崩。

## 7. 预期结果

### 红玉（仍 10 波，0 告警）
```
1 [1]     74兵 1升           4 [5]    39兵 1升           8 [12,13] 99兵 1升
2 [2,3]   74兵 1升 ←德拉加尔   5 [6,7]  93兵 1升 ←烈焰之咽   9 [14]    40兵 1升 ←Ryvati
3 [4]boss 12兵 2升            6 [8,9]  106兵 1升          10 [15]boss 0兵 2升
                            7 [10,11]boss 14兵 2升
```
段 [1,2,3] 切点 = pull2（Draghar 9.7M）；[5,6,7] = pull6（Flamegullet 9.7M）；[12,13,14] = pull14（Ryvati 6.5M，> Tempest Channeler 5.2M）。boss 波 [4]/[10,11]/[15] cap2、2 升腾不拆。

### 密谋
段 [11,12,13] 锚点 = pull12（Shivan Punisher / Fel Invoker 5.5M）→ `[11] | [12,13]`，2 升腾均分（各 1），大怪包 [12,13] 拿到升腾，不再甩给 4 兵力的 pull 13；pull13 原子告警消失。（密谋其余波次待重导时以实际数据核对。）

## 8. 测试影响

- `align.test.js`：`loadEnemyMeta` 增加 `health` 字段断言。
- `waves.test.js`：
  - **不变**：`ascCountPerPull` Voronoi 单测、`splitWaveByAscCap` 5 条单测、boss 波用例（line 50「Boss波升腾超上限2…」`[[1],[2],[3,4],[5],[6]]` + 告警 pull6）、line 59「纯小怪…拆成两波」`[[1],[2],[3],[4,5,6]]`（锚点回退切在 pull4 前，与旧 Voronoi 结果一致）、line 10 默认用例、line 68 自洽用例。
  - **改**：line 111「缺少Boss进战证据…小怪升腾上限1仍拆」——旧期望 `[[1],[2],[3,4,5],[6]]`+告警 pull6 是 Voronoi 退化产物；新（无 `pullMaxHealth` 回退，3 升腾均分）期望 `[[1],[2],[3],[4],[5,6]]`、`reason="asc-cap"`、**无告警**。
  - **新增**（用「段内 pull 起始时刻相同」的 fixture 走锚点真路径）：锚点=最高血 pull → 切点在其前、升腾均分、子窗中点归属；锚点是首 pull 的回退；血量相同 pull 号小者优先；pull 不够时的原子告警；缺 `pullMaxHealth` 的顺序回退。
- `cli.test.js`：**不变**（line 148 boss 用例、line「手工usage」`[[1],[2],[3,4],[5,6]]` 均属 boss/无拆分路径）。若 `run()` 的默认 input 需带 `pullMaxHealth` 才能触发锚点，另加一条小怪锚点端到端用例，不改既有。
- 全绿标准：`node --test tools/wclplan/*.test.js` 全过。

## 9. 非目标

- 不改 boss 上限（2）/ 小怪上限（1）本身。
- 不改 boss-entry、confirmed-combat、连续战斗段的判定。
- 不引入坐标聚类（HP 锚点已足够且更稳；坐标留作将来可选信号）。
- 不重新抓取 WCL 伤害事件（当前管线不含逐目标伤害，本设计不依赖它）。

## 10. 交付与回滚

实现后波数/波形变化 → **routeKey 变化**：红玉、密谋两份产物都要重导，游戏内需先导入**新 MDT 路线串**、再跑新 routeKey 的 `importplanpack`/`importratiopack`。重导后按 `feedback-wcl-wave-acceptance` 逐波核验（配对一致 + 分波合理分别说明）。
