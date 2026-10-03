# Agent Collective Decision Framework（ACDF）设计备忘

| | |
|---|---|
| 版本 | v0.2（并入顾问第三轮实现审查；对应参考实现 v0.2） |
| 日期 | 2026-10-04 |
| 性质 | 设计备忘与实现规格。v0.2 的对象、状态机与接口已由 `assets/erc-acdf/contracts/` 的参考实现和 `test/` 的 117 个测试落地；仍不是 ERC 文本 |
| 仓库 | `acd-framework` · 本文路径 `docs/design-memo-zh.md` |
| 起草 | Gary Yang（FinChip）· 由 Claude 协助整理 · 顾问两轮评审意见已并入 |

**标注约定**

- 【已定】三轮讨论已确定的原则或决定，后续文本不再重开
- 【提案】本文首次提出、需要拍板
- 【待定】方向已定、细则留给后续回合
- 【R3】顾问第三轮（实现审查）的修正或新增决定；本版新增

**v0.2 相对 v0.1 的变更摘要（R3）**：POST_ACK 改为"先立案、后确认、再受理"，确认必须发生在受理与投票之前，Advisory 受理后不得升级为 Binding；受理后默认不得单方撤回；结果接纳模式落到机构（Body）而非整份规则；Final 为真正终局，不再被后续轮次取代，Deciding→Final 的条件改为"不存在剩余合法后续程序"；新增决定：上诉轮未形成决定时保留最近一个有效实体决定；VETO 在否决窗口内不得提前放行；规则哈希绑定全部执行参数（policyId = keccak256(abi.encode(PolicySpec))），首版采用不可升级内核与内置固定版本机构类型；8414 适配按真实 ABI、两类截止（judgmentWindow 与 settleBy）与现有费用机制接入，不假设 judgmentFee；"两端测试通过"降格为"两个设计用例已展开"，可执行测试见 `test/`。

---

## 0. 这份文件是什么

这是 ACDF 的设计备忘。它的任务有三个：把三轮讨论形成的原则固定下来；给出一套对象模型和状态语义，并用两端测试证明最简单的 K-of-N 和最复杂的多机构配置能在同一套语义下写出来；列出下一回合（英文 ERC 骨架、参考实现）必须先拍板的待决项。

阅读顺序建议：第 1–2 节看定位与原则；第 3–4 节是全文核心（对象与状态）；第 5–9 节逐层展开；第 12 节两端测试是验收；第 14 节是决定记录与待决清单。

---

## 1. 定位

### 1.1 一句话定义【已定】

> ACDF 让有资格的参与者，在明确的授权范围内，按照可验证、可组合的规则，形成具有明确效力的共同决定。

展开为四句【已定】：**以决策规则组织合议，以授权约束效力，以注册表确定正式记录，以适配器连接执行。**

### 1.2 命名【已定】

| 使用位置 | 名称 |
|---|---|
| 正式 ERC 标题 | Agent Collective Decision Framework |
| 英文简称 | ACDF（CDF 撞统计学术语，ACD 撞呼叫中心术语；建议保留 ACDF，最终由 Gary 定） |
| 正式中文名 | Agent 集体决策框架 |
| 中文交流简称 | Agent 合议机制 |
| 争议处理这一具体应用 | Arbitration Profile / 仲裁配置 |

不采用 "AI Arbitration"（把框架锁死在纠纷场景，且 arbitration 在法律上有特定含义）、"Agent Adjudication"（司法词汇，留给裁判型模块）、"Agent Governance Framework"（比规范实际承担的责任更广：不管成员管理、财政、组织存续、执行调度）。

通用层术语不用司法词汇：Issue（事项）、Decision（决定）、Result（正式结果）；进入仲裁配置后才使用 Case、Ruling。

### 1.3 它是什么、不是什么

ACDF 是集体决策的最小可互操作内核，加一组规范性可选配置（profile）。

它不是：仲裁系统（仲裁是一个 profile）；完整治理系统；授权委托协议（授权是约束条件，不是协议主体）；信用系统（信用由 ERC-8419 / ERC-8434 / ERC-8004 表达，ACDF 只消费资格条件、产出证据）；执行器（外部效果由接入合约或受权的执行模块落实）。

### 1.4 在标准族中的位置【已定】

| 标准 | 角色 | 与 ACDF 的关系 |
|---|---|---|
| ERC-8434 AID | 标识主体 | 资格规则的身份锚；ACDF 永不触碰 AID 生命周期（retire 只能由身份锚发起） |
| ERC-8419 KYA | 表达与验证信任条件 | 资格规则引用 KYA 断言与策略；ACDF 的正式结果可作为 KYA scheme 的证据，但 ACDF 不直接改任何人的信用 |
| ERC-8414 Task Tenders | 任务承诺与结算 | ACDF 通过适配器成为 acceptanceAuthority 背后的一个实现；8414 内核不依赖 ACDF |
| ERC-8338 Executable Skills | 技能资产 | 技能质量争议、技能准入等事项的标的来源 |
| ERC-8004 | 身份 / 信誉 / 验证注册表 | 身份与信誉的数据来源；可选桥把结果有损镜像到 Validation Registry |

一句话：**AID 标识主体，KYA 表达与验证信任条件，ACDF 组织获得授权的共同决策，Task 等应用执行各自已承诺的后果。**

### 1.5 与现有工作的关系（Magicians 必答题）

| 现有工作 | 它做什么 | ACDF 的差异与关系 |
|---|---|---|
| ERC-792 / ERC-1497（Kleros） | Arbitrable / Arbitrator 接口；证据事件 | 仲裁配置做有定义、有测试的兼容适配；1497 事件直接复用为证据表达 |
| ERC-8033 Agent Council Oracles | Info Agent commit-reveal 提交答案，单一 Judge 聚合，bond 罚没，可选 dispute | 面向信息查询的具体流程；可表达为 ACDF 的一个配置（受权提交者接纳 + 争议轮）；ACDF 的差异在授权、资格、机构组合、通用规则与结果效力 |
| ERC-8183 Agentic Commerce | 单一 evaluator 地址，complete / reject 终局；明确不含争议解决与多方投票 | ACDF 适配器可以是 evaluator；核心结算一旦完成，外围程序不能推翻 |
| ERC-8226 Regulated Agent Mandate | 委托人→Agent 的范围、时间、金额受限授权 | 同形不同向：8226 授权 Agent 去做，ACDF 的授权承认一套规则去决定；可互补（超额动作需 ACDF 结果） |
| OpenZeppelin Governor / Timelock | 代币加权投票 + 时间锁执行 | 决策与执行分离的现成实践；Governor 是 ACDF 参数空间中的一个点 |
| Safe 多签 | 固定名单 K-of-N | ACDF 最小配置的等价物，加上事项绑定、结果记录与 NoDecision 语义 |
| Kleros Court | 押金加权抽签、谢林点激励、上诉扩员 | 抽签与上诉扩员作为配置借鉴；不采用"与多数一致即正确"的激励默认 |
| Polkadot OpenGov | Origins / Tracks、Approval / Support 曲线、确认期、Fellowship | 借鉴权力分工、授权来源、制度可修改性与双门限曲线；不借鉴网络安全角色拼成的流水线 |

提案中不宣称这是一片空白：8033 已标准化面向 Agent oracle 的 Info / Judge 流程。差异放在通用的授权、参与资格、机构组合、决策规则与结果效力上。

---

## 2. 设计原则【已定】

| 编号 | 原则 | 一句话解释 |
|---|---|---|
| P1 | 授权先于资格 | 信用决定一个主体是否值得被授予某类决策资格；授权决定它究竟有权决定什么。表决形成共同决定，但不凭空创造权限，也不自动证明真理 |
| P2 | 注册表为规范记录源 | 规则版本、事项绑定、决策状态、正式结果及终局性以注册表为准；接入合约在自身权限内落实事先承诺的效力；只有外围副本才叫镜像 |
| P3 | 规则版本化 | 旧版保留、新版发布；新事项绑新版，在审事项按承诺版本走完；更新权限必须预先存在 |
| P4 | 资格、选取、权重三分 | 有资格不等于每次入选；信用高不等于票权无限 |
| P5 | 终止可确定，NoDecision 合法 | 每项程序有可确定的终止路径；未形成决定是正式结果，不被包装成否决或通过；后果事前承诺 |
| P6 | 机构以代数组合 | 多机构的决定用 ALL / ANY / K-of-M / VETO 组合，绝不把票池合并加权 |
| P7 | 机械验证不是投票 | 可复算的验证走验证器路径（8414 的 verifier），不是"0-of-0 投票"；乐观确认也不是 θ=0，它需要挑战资格、窗口与升级规则 |
| P8 | 没有全局根 | 每个治理域的根是其自身的授权来源；标准不设中央注册表，也不设对全部 Agent 有权的"最高法院" |
| P9 | 决策与执行解耦 | 核心不因形成决策取得外部资产控制权；程序状态、结果类型、执行状态三个维度分开表达 |
| P10 | 不以"与多数一致"定义正确 | 程序履约可得报酬，可证明违规可受处罚，判断质量用后续可观察结果或独立复核更新 |

---

## 3. 对象模型

### 3.1 总览

```
 Decision Policy（决策规则：版本化、内容寻址、属于某个规则族）
        │  事项在立案时绑定一个规则版本
        ▼
 Issue（事项）── bindings[] ──► Consumer（接入合约）承诺接受结果并在自身权限内落实
   │   subject / question / outcomeSpace / effectCandidates / disposition / snapshot
   ▼
 Body Instance(s)（机构实例：按规则生成，可多轮）
   │   ballots ──► Body Decision ∈ { Pending, Decided(o), NoDecision(r) }
   ▼   单机构直接采用；多机构按组合代数合成
 Result（正式结果）= 程序状态 × 结果类型
   ▼
 Enactment（执行）：接入合约 / 执行模块读取结果、自行核验、落实效果；执行状态由接入方记录
```

六类对象：Decision Policy、Issue、Authorization（作为接入合约的接纳记录与 Issue 的 bindings 存在，不是独立的"授权书"对象）、Body 与 Body Decision、Result、Enactment Record。证据（Evidence）作为事件附着在 Issue 上。

### 3.2 Decision Policy（决策规则）

规则是**模板**，回答"这类事按什么制度决定"。规则内容寻址（policyId = 规范化描述的哈希），一经登记不可修改；修改以发布新版本实现，版本之间通过**规则族**（policy family）关联。规则族记录更新权限：谁可以在这个族里发布新版本。

| 组件 | 回答的问题 | 最小配置（MUST 支持） | 开放范围（profile） |
|---|---|---|---|
| eligibility 资格 | 谁可进入候选池 | 固定名单（ROSTER） | 信用合格 Agent（8419 / 8434）、押金、领域断言、利益冲突排除 |
| selection 选取 | 本次由谁参与 | 名单全体 | OPEN / NOMINATED / SORTITION / DELEGATED |
| weight 权重 | 意见如何计入 | 等权 | 信用加权、押金加权、锁定期加权；运营者上限、多样性条件 |
| outcomeSpace 结果空间 | 答案的形状 | BINARY | CATEGORICAL / SCALAR / RANKED / SET |
| aggregation 聚合与通过 | 何时形成何种决定 | K-of-N 绝对阈值 | 参与 / 赞成 / 支持三门限 + 确认期 + 时间曲线；加权中位数；Condorcet 等 |
| composition 机构组合 | 多机构如何合成 | 单机构 | ALL / ANY / K-of-M / VETO，有限无环，可带顺序依赖 |
| timing 时序与时钟 | 各阶段多长、用什么钟 | 单一投票窗口；timestamp 钟 | 组庭、取证、commit、reveal、确认、挑战各窗口；block 钟 |
| appeal 上诉 | 能否复议、几轮、谁能提 | 0 轮 | 有限轮、换人扩员、押金、总时限 |
| termination 终止 | 何时、为何产生 NoDecision | 截止未达阈值 | 平票、参与不足、依赖失效、数据不可用 |
| resultAcceptance 结果接纳【R3：机构级字段】 | 正式结果如何进注册表（每个机构各自声明，规则只提供默认） | 链上逐票计票 | 签名选票批量接纳（与链上计票共用同一计票语义）、受权提交者（注册表只核验提交资格、结果绑定与时序，不复算其内部投票） |
| dependencies 依赖固定【R3】 | 引用的外部模块如何锁定 | 无外部模块：内核不可升级，机构类型内置且固定版本 | 可变依赖（动态 KYA 撤销、可升级验证器）另列明确配置，声明动态范围、检查时点与失效后果；地址与代码哈希本身不构成冻结（ERC-1967 实现槽可变，固定代码也可能读取可变存储） |
| update 更新权限（族级） | 谁能发新版本 | 指定账户 | 多签、委员会、另一个 ACDF 决定 |
| emergency 紧急条款 | 能否暂停、谁、后果 | 无 | 预声明的暂停条件、权限与对在审事项的影响 |
| instantiable 可实例化参数【R3】 | 哪些参数在立案时填、谁填 | 无（v0.2 参考实现：规则固定全部机构与窗口；事项只带标的、议题、效果与处置） | 候选项、面板规模区间、窗口区间；设定者由规则与授权关系共同确定，接入方承诺最终参数，发起人不能擅自降低门槛；Advisory 也必须有合法的参数设定路径 |
| fees 费用与押金 | 谁付、如何分配 | 无 | 立案押金、参与押金、上诉押金、程序报酬 |

【R3】规则哈希必须绑定真实执行参数。v0.2 参考实现中 `policyId = keccak256(abi.encode(PolicySpec))`，PolicySpec 包含全部影响资格、票权、阈值、组合、时序与终局的参数，并整体存储在链上；不存在"JSON 写 3-of-5、合约收 K=2"的空间。`descriptorHash` 只是对人类可读描述的引用，属于被哈希的对象但不影响执行。JSON 描述（`assets/erc-acdf/schemas/policy-spec.schema.json`）是链上结构的镜像，供其他语言复现编码；跨语言向量见 `assets/erc-acdf/vectors/policy-id.json`（ethers v6 编码 vs solc 编码）。

### 3.3 Issue（事项）

事项是**绑定**：把一个具体标的、一个具体议题、一个规则版本、一组接纳关系固定在一起。

| 字段 | 含义 | 由谁确定 | 冻结时点 |
|---|---|---|---|
| issueId | 事项标识（含 chainId、注册表实例） | 注册表 | 立案 |
| policyId | 绑定的规则版本 | 绑定创建者 | 立案 |
| params | 规则允许实例化的参数 | 按规则的 instantiable 声明，设定者受限 | 受理 |
| subject | 标的：(chainId, contract, id, dataHash) | 立案人 | 立案 |
| question | 议题：schema 化描述的哈希（例："交付 S 是否满足任务 T 的验收标准"） | 立案人，须落在接纳范围内 | 立案 |
| outcomeSpace | 本事项的结果空间实例（具体候选项或数值区间） | 绑定创建者 | 受理 |
| effectCandidates | 每个结果对应的候选效果（接入合约的动作与幅度） | 接入合约 | 受理 |
| bindings[] | 已核验的接纳关系：consumer、接纳模式、范围引用 | 接入合约 | 受理 |
| effectClass | Binding（有接纳）/ Advisory（无接纳） | 由 bindings 推出 | 受理 |
| disposition | NoDecision 的处置引用 | 接入合约（随常设接纳或立案时） | 受理 |
| filer | 立案人及其立案资格 | 规则 initiation + 接纳范围 | 立案 |
| deadlines | 接入合约硬截止；本事项各窗口的绝对时点 | 规则 + 接入合约 | 受理 |
| snapshot | 资格与权重快照承诺 | 受理过程 | 受理 |
| evidenceRoot | 证据引用（1497 事件） | 各方 | 可追加至规则声明的截止 |

立案（Filed）与受理分开：立案登记意图，受理完成核验与冻结并开启第一轮。CONSUMER_FILED 与 STANDING_ACCEPTANCE 在一笔交易中原子完成；POST_ACK 停在 Filed 直到接入合约确认。参考实现不设独立的 Admitted 状态，受理即 Filed → Deciding。

### 3.4 Authorization（授权）

授权回答"谁承认这套规则对哪些事项和效果有决定权"。它不是独立对象，而是两处结构化数据：接入合约一侧的接纳记录（接入合约自己的权限系统，或在注册表登记的常设接纳），以及事项一侧的 bindings。详见第 5 节。

### 3.5 Body 与 Body Decision（机构与机构决定）

机构是规则中"资格 + 选取 + 权重 + 聚合"的一个组合在某个事项、某一轮上的实例。最小配置恰有一个机构；组合配置是一个有限无环的机构图。

机构决定取三类值：Pending（未完成）、Decided(outcome)（已决；二元时即同意或否决）、NoDecision(reason)（终止但未形成决定）。对应顾问要求的四值：未完成、同意、否决、终止未决。

NoDecision 的原因码（v0.2 参考实现）：QUORUM_NOT_MET（名单机构截止未达任一阈值）、SUBMITTER_SILENT（受权提交者窗口内未报告）、NO_CLEARANCE（REQUIRE_CLEARANCE 下否决机构既未否决也未放行）、NOT_REACHED（组合节点无法从子节点形成决定，含"所需共同批准未形成"）、TOTAL_TIMEOUT（硬截止到达时本轮仍 Pending）、NO_ACCEPTANCE（POST_ACK 窗口届满无确认而关闭）；VETOED 是 Decided(no) 的原因而不是 NoDecision。为非二元与未来 profile 保留：TIE、DEPENDENCY_FAILED、DATA_UNAVAILABLE、EFFECT_MISMATCH。

### 3.6 Result（正式结果）

正式结果是两个独立维度的组合：

- **程序状态**（procedure state）：Filed → Deciding → Provisional → Final；另有 Withdrawn。
- **结果类型**（outcome type）：None（尚无）/ Decided(outcome) / NoDecision(reason)。

合法组合：Filed × None、Deciding × None、Provisional × Decided、Provisional × NoDecision（该结果类型可上诉时）、Final × Decided、Final × NoDecision。"已经终局，但结果是 NoDecision"是正常状态。

正式结果附带：policyId、轮次、各机构决定、计票承诺（票数或票权汇总、选票集合的承诺）、形成时点、终局时点。

### 3.7 Enactment Record（执行记录）

执行状态按 (consumer, effectId) 记录：NotEnacted / Enacted(ref) / Failed(reason)。执行状态的权威在接入合约（那是它的状态）；注册表可以提供信息性的执行日志入口，但不以日志覆盖接入合约的状态，也不因某个接入方执行失败反向修改决定。资金类效果的防重复由接入合约负责。

### 3.8 Evidence（证据）

复用 ERC-1497 的事件表达。证据以内容寻址、带 schema 与大小上限的信封提交。参与者必须把证据当作数据而不是指令（见第 10 节）。

---

## 4. 状态机

### 4.1 程序状态迁移

| 迁移 | 触发 | 条件 |
|---|---|---|
| — → Filed | 立案人调用 file | 立案人满足规则 initiation；标的与议题形式合法 |
| Filed → Deciding（受理） | 受理：CONSUMER_FILED 与 STANDING_ACCEPTANCE 与立案原子完成；POST_ACK 在接入合约确认后完成 | bindings 核验通过（5.2）；剩余窗口检查通过（`admittedAt + maxTotalDuration ≤ consumerDeadline`，9.4）；同一义务无其他未终局的 Binding 事项；快照完成；第一轮即时开启 |
| Filed → Deciding（Advisory 受理） | POST_ACK 窗口届满无确认，且规则允许 Advisory | consumer 与效果清空；此后不可升级为 Binding |
| Filed → Withdrawn | 立案人撤回；或 POST_ACK 窗口届满无确认且规则不允许 Advisory | 【R3】单方撤回只在 Filed 阶段 |
| Deciding → Provisional | 本轮合成结果形成（Decided 或 NoDecision） | 存在剩余的合法上诉机会（轮数未用完且该结果类型可上诉），且结果形成时点 + 上诉窗口尚未过去 |
| Deciding → Final | 本轮合成结果形成 | 【R3】不存在剩余的合法上诉或挑战机会：从未允许上诉、轮数已用完、该结果类型不可上诉，或上诉窗口已从结果形成时点起算届满（迟到的结算不能延长程序） |
| Provisional → Deciding | 上诉被受理 | 有上诉资格者在窗口内提出；新一轮重建全部机构实例，按原规则版本运行 |
| Provisional → Final | finalize（无许可调用） | 上诉窗口届满无上诉 |
| Deciding / Provisional → Final | enforceHardDeadline（无许可调用） | 超过 `admittedAt + maxTotalDuration`；若当前轮仍 Pending 则记为 NoDecision(TOTAL_TIMEOUT) |

【R3】Withdrawn 只能从 Filed 进入，且只能由立案人发起。一旦受理，名单、快照与窗口已经形成，即使尚无第一票也不得撤回重来，否则立案人可以挑选面板；受理后的共同撤销只能作为预声明扩展。接入合约不能单方面撕毁在审事项的绑定（P3）。参考实现把"受理"实现为 Filed→Deciding 的原子迁移，不设独立的 Admitted 状态。

### 4.2 结果类型的确定

结果类型由当前轮的机构决定按组合规则合成（单机构直接采用）。Decided 必须落在受理时冻结的 outcomeSpace 内；NoDecision 必须携带原因。

【R3】Provisional 的结果可以被合法上诉产生的后续轮次结果取代；**Final 不得再由同一事项的后续轮次取代**。以后需要纠正或改变业务状态，只能通过新的获授权事项进行；旧决定作为历史事实保留，不会重新变成"从未终局"。

【R3 新增决定】上诉轮未形成决定时，默认保留最近一个有效的实体决定：第一轮明确拒收、败方上诉、第二轮因参与不足而 NoDecision，终局采用第一轮的拒收；第二轮的 NoDecision 单独记录，不消灭原决定。只有在任何轮次都没有实体决定时才终局为 NoDecision。因此 Result 同时记录 `roundCount`（最后尝试的轮次）与 `sourceRound`（最终采用决定的轮次），二者可以不同。需要"重新审理即撤销原结果"的配置可以另行声明，不作为隐含默认。

【R3】上诉覆盖哪些机构必须写清：v0.2 的上诉重建**全部**机构实例（包括审核庭），按原规则版本重新运行；"沿用上一轮某机构的决定"是未来的显式配置。

时间安排冻结的是计算规则而非全部未来时点：受理时冻结初始时点、总硬截止、各阶段时长、启动条件与计算方式；后续轮次的实际开启时点按这些规则记录。上诉窗口从**结果形成的时点**起算，不从结算调用起算，所以迟迟不调用 settle 不能延长程序；总超时处置覆盖 Deciding 与 Provisional 两种非终局状态；"任何人可以 finalize / enforceHardDeadline"提供的是可调用路径，不意味着链会自动替你执行。

### 4.3 执行状态

执行状态独立于前两者：同一份 Final × Decided 可被多个接入方读取，各自成功或失败。接入方在执行前自行核验（9.4）。

### 4.4 程序终局与链终局

程序终局（Final）是注册表记录的程序事实；它不替代承载该记录的区块链状态是否已达所需确认程度。接入方（尤其跨链读取方）需自行声明链终局假设。

---

## 5. 授权层

### 5.1 授权是什么、不是什么【已定】

授权是接入合约对以下内容的承诺："我接受注册表 R 中规则 P 对事项类别 C、标的集合 S 的终局结果，并在自身权限内落实效果 E（含上限与有效期）。"

- 某人单方面在注册表写"我有权处分合约 X"不产生任何权限；权限只能来自接入合约自己的接纳行为。
- 接入合约不能因为不喜欢结果而重新数票或更换门槛：通过与否以注册表记录为准；允许动哪笔钱、是否已执行、当前是否仍满足执行条件由接入合约检查（P2）。
- "权力来源只有产权、契约、结社、衍生四种"作为动机陈述留在本备忘与 Rationale，不写成规范公理。

### 5.2 三种接纳模式【提案】

| 模式 | 机制 | 典型场景 | 注册表在受理时核验什么 |
|---|---|---|---|
| CONSUMER_FILED（接入合约自己立案） | 接入合约或其适配器调用 file，msg.sender 即 consumer，接纳随立案隐含，受理原子完成 | 8414 适配器、8183 evaluator、792 Arbitrable 的 createDispute | 立案人 == 绑定中的 consumer。【R3】这只证明该 consumer 发起了立案；适配器必须自行核验它确实持有所声称的业务权限（8414 适配器核验 `acceptanceAuthorityOf(tokenId) == adapter`），不能仅凭"调用者自称适配器"登记对任意任务的有效绑定 |
| STANDING_ACCEPTANCE（常设接纳） | 接入合约预先登记：接受哪些规则版本或规则族（引用，不复制规则）、事项类别、标的约束、结果空间约束、谁可立案、处置、有效期、上限；立案人在其范围内立案 | 组织章程：任何成员可提案参数变更、成员准入 | 事项的每个字段落在常设接纳范围内；常设接纳由 consumer 本人登记且未过期 |
| POST_ACK（先立案、后确认、再受理）【R3 修订】 | 任何人立案并指名 consumer，事项停留在 **Filed**，不能投票；consumer 在规则声明的 ackWindow 内确认（acknowledge）并提交最终效果与处置，事项才受理为 Binding；窗口届满无确认则按事前声明：规则允许 Advisory 时受理为 Advisory，否则关闭（Withdrawn，原因 NO_ACCEPTANCE） | 一方先发起、另一方随后同意受裁的争议 | 确认由指名的 consumer 发出且在窗口内且事项仍为 Filed；确认时冻结 outcomeSpace 与 effectCandidates。已受理为 Advisory 的事项**不得**在看到投票或结果后原地升级为 Binding；后续有主体愿意采用其结果，须建立新的接纳记录或新事项 |

常设接纳是接入合约对自己的声明，引用确定的规则版本，不维护第二份规则副本（P2）。它不是"授权书注册表"：它不授予任何人权力，只声明接入合约将接受什么。

### 5.3 Binding 与 Advisory【提案】

bindings 非空的事项为 Binding；为空的为 Advisory。Advisory 事项走完整程序、形成正式记录、不产生任何硬效力；8419 的 scheme 可以把它当作证据在自己范围内解释。这给"靠信用而不靠法院影响世界"一条正式的路，也让"一个域的决定不强制其他域"在对象层面有了表达。规则可以对 Advisory 事项要求押金以防滥用，或禁止 Advisory（v0.2 的 `allowAdvisory`）。

【R3】Binding 限定到具体接纳方和效果。"bindings 非空"可以作为展示标签，但执行器不能把它理解成"这份决定对所有涉及的主体都有约束力"：v0.2 每个事项只绑定一个 consumer；若一项效果需要两个资源控制方共同接纳，必要接纳集合及其完成条件属于未来扩展，受理时一并检查。

【R3】同一份业务授权下的同一项决策义务，只能有一个当前有效的 Binding 事项。v0.2 以 `obligationKey = keccak256(consumer, subject, question)` 标识义务：前一事项未终局（非 Final / Withdrawn）时不得再立案；重审只能通过既定上诉或接入方自己的重新立案规则进行。不同治理域对同一事实分别作决定仍然允许（不同 consumer 是不同义务）；禁止的是同一笔执行义务挑选有利裁决。

### 5.4 立案冻结与非扩张【已定】

受理时冻结：规则版本、params、outcomeSpace、effectCandidates、bindings、disposition、资格与权重快照、分母确定方式。看到票数后不得更换统计口径。确需实时检查的条件（如资格断言被撤销是否使选票失效、在哪一时点之前）作为**动态依赖**在规则中预先声明。

非扩张：结果只能落在冻结的 outcomeSpace 内，效果只能是冻结的 effectCandidates 之一，幅度不超过接纳上限。任何决定都不能扩大其所依据的授权。

### 5.5 版本、更新权限与紧急条款【已定】

- 发布新版本需要规则族的更新权限，该权限在族创建时确定，可以是指定账户、多签、委员会或另一个已获授权的 ACDF 决定；本次决策不能临时宣布自己拥有更新权限。
- 发布新版本不等于既有接入方自动采用：接入方的常设接纳或立案绑定指向具体版本。接入方可以选择接受"族 F 中由权限 U 发布的任一版本"，这是接入方自己的选择，并且只影响新事项。
- 【R3】规则冻结必须从"文本承诺"落实为"执行参数承诺"：所有影响资格、票权、阈值、组合、时序和终局的参数都进入可验证的规范编码承诺（v0.2：整份 PolicySpec 上链并哈希为 policyId，跨语言向量覆盖字段顺序、整数精度、数组顺序）。地址、代码哈希和管理员白名单不能单独证明冻结：ERC-1967 代理的实现地址在存储槽中可变而代理代码不变，固定代码也可能读取可修改的阈值或名单。首版因此采用**不可升级内核 + 内置固定版本机构类型 + 与规则绑定的执行配置**；确需动态 KYA 撤销、可升级验证器等情况，另列配置声明动态范围、检查时点与失效后果，不再称为完全冻结。
- 普通变更保护在审事项。紧急暂停若确有需要，必须在规则中预声明触发条件、权限与后果（例如只暂停新立案、不触碰在审事项），不采用"任何撤销都等通知期"的一刀切。v0.2 参考实现：常设接纳可由 consumer 撤销，撤销只阻止新立案，在审事项按承诺完成。
- 时钟一致性：一个注册表实例统一使用一种时钟（v0.2：timestamp，按 ERC-6372 披露 `clock()` / `CLOCK_MODE()`）；不得把区块数按平均出块时间换算成"保证不超时"的秒数。

### 5.6 不进 v1 内核的内容【已定】

完整授权树、递归再授权、共享额度管理（父额度 100 分给两个子授权各 100 的问题）属于额外机制，留给后续 profile。v1 只标准化规则更新边界与版本保护。

---

## 6. 资格、选取、权重

### 6.1 框架要求与信用合格 Agent 配置【已定】

框架层要求：资格规则**可验证**，且在受理时形成快照。固定名单 3-of-5 符合最小框架，但它不能仅凭名单存在就声称实现了"信用合格 Agent 合议"。

信用合格 Agent 配置（Credit-Qualified Agent Profile，Finch 默认）严格绑定 ERC-8419 与 ERC-8434，规定**完整核验语义**，不假设某个现有函数包办一切：

- 身份锚：8434 AID 处于 Active，与 8004 agentId 一一绑定；Stale / Retired 不合格。AID 的绑定与存活状态**不是**反女巫证明：心跳证明密钥控制，不证明行为质量。
- 信任条件：规则指定的 8419 scheme 与等级，核验含发行方接纳、准入域、有效期、与身份锚的绑定、声明的外部条件。KYA 的链上 evaluate 是可选扩展，配置必须说明链上局部检查与完整策略满足之间的差距由谁补足。
- 领域绑定：资格必须与事项领域相关。资金履约历史不自动构成合约安全或事实核查的专业资格；不同 scheme 的等级不得不加解释地揉成"全能信用分"。
- 利益冲突排除：当事方、当事方的关联主体（按 8434 绑定关系与声明的关联）不进入该事项的候选池。
- 可选押金。

### 6.2 三分与选取模式【已定】

资格决定谁可进候选池；选取决定本次由谁参与；权重决定意见如何计入。三者分别配置、分别快照。

选取模式：OPEN（全体合格者可投）、ROSTER（固定名单）、NOMINATED（当事方或提名人提名，可设互相剔除规则）、SORTITION（可验证随机从候选池抽取，可按信用或押金加权抽取，面板规模由规则或事项客观属性决定）、DELEGATED（按领域委托）。

提名与担保分开：提名是"推荐其参选"；担保是"为其承担损失"，必须有事项范围、有效期、责任上限与触发条件，不能推导成"老 Agent 的信用可以无限借给新 Agent"。提名可以帮助冷启动，但不能成为批量制造治理权的信用印钞机。

### 6.3 权重与独立性处理【已定方向】

权重和独立性处理方式必须在规则中明确且可核验；具体算法不写死。至少分开三个问题：

| 问题 | 识别对象 | 可配置的处理 |
|---|---|---|
| 控制权集中 | 多个 Agent 是否受同一主体控制 | 每运营者票权上限、每运营者入选上限 |
| 判断错误相关 | 是否共享模型、信息源、记忆或偏差 | 模型 / 信息源多样性条件 |
| 利益一致或冲突 | 是否从同一结果获益，或与当事方关联 | 冲突排除、回避 |

是否满足这些条件，必须说明证据来源与剩余信任假设。自报"不同运营者"不是独立性证明。"同一模型跑出的 N 个 Agent 等于一票"不作为规范表述。

### 6.4 资格快照的生成方式【待定】

候选池较大且资格依赖链下或昂贵核验时，快照如何生成：链上逐个核验、提交承诺加挑战期、或 ZK 证明。留给资格层回合。

---

## 7. 表决与聚合

### 7.1 结果空间类型

BINARY（两项）、CATEGORICAL(m)（m 选 1）、SCALAR(range, unit, precision)（数值，典型用于"支付几成"）、RANKED（排序）、SET（任意子集）。接入合约只接纳自己能落实的类型（11.1）。

### 7.2 最小配置 K-of-N 的完整语义【提案】

固定名单 N，等权，一个投票窗口。

- 有效赞成票 ≥ K：Decided(yes)，可即时形成。
- 有效否决票 ≥ N − K + 1（赞成已不可能）：Decided(no)。这是机构的明确否决，不是未决。
- 窗口截止仍未满足上述任一条件：NoDecision(QUORUM_NOT_MET)。
- 每名成员一票；迟到票无效；最小配置不允许改票（第一票有效），改票与 commit-reveal 留给 profile。
- 弃权在最小配置中等同未投；一般配置可有显式 ABSTAIN 用于参与门槛计数。

【R3】这是对**指定提案的批准规则**，不是双方各需 K 票的对称裁判："no" 表示该提案被该规则明确阻止，不自动构成对相反实体命题的认定。4-of-5 下两票反对就能阻止通过，这不代表四名成员认定反方正确，只代表提案已无法达到四票赞成。在二元验收中可以事先授权把它映射为拒收；不能把这一解释无条件推广到有罪 / 无罪、两个竞争方案或事实真假；需要双方各自达到门槛的裁判另设显式正反阈值配置，中间区域产生 NoDecision。两个阈值不可能同时成立：同时成立需要 K + (N − K + 1) = N + 1 张有效票，而全体只有 N 张。参考实现固定 N ≥ 1、1 ≤ K ≤ N、成员不重复、分母不变，并按 (事项, 轮次, 机构, 投票人) 防重复——换一个签名 nonce 得不到第二票。

### 7.3 一般二元通过条件【已定】

可选的二元表决配置可分别启用三个条件，W_E 为按本轮规则在快照确定的全部可用票权：

- 参与门槛：(W_yes + W_no + W_abstain) / W_E ≥ q
- 赞成比例：W_yes / (W_yes + W_no) ≥ a；分母为零时视为不满足
- 支持比例：W_yes / W_E ≥ s

启用的条件须在**确认期**内持续成立；a 可以是随已流逝时间下降的声明曲线（借 OpenGov 的 Approval / Support 思路，不逐字复刻）。所有比较以整数交叉相乘实现，不做除法取整。例：100 份票权中 10 份参与、8 份赞成，赞反票赞成率 80%，全体支持率 8%，是否通过取决于启用了哪些条件。

### 7.4 非二元聚合

CATEGORICAL：加权多数或声明的 Condorcet / IRV；SCALAR：加权中位数（对离群值鲁棒），平局取下界或上界由规则声明，结果钳制在区间内；RANKED：Schulze / IRV；SET：逐项阈值。平票规则必须声明，否则产生 NoDecision(TIE)。

### 7.5 结果接纳模式【提案】

| 模式 | 机制 | 验证责任 |
|---|---|---|
| ON_CHAIN_TALLY（链上逐票） | 每票一笔交易，注册表按已接纳的选票确定性计票，finalize 无许可 | 注册表 |
| SIGNED_BALLOTS（签名选票批量接纳）【R3：首版的"验证汇总"】 | Agent 链下签署 EIP-712 选票（绑定 chainId、注册表地址、issueId、轮次、机构、投票人、立场；**不含 nonce**，投票人身份即唯一键），任何人批量提交，注册表逐票验签（EOA 用 ECDSA，合约账户用 ERC-1271）并按**同一计票语义**计入；接纳时点为提交区块 | 注册表验证签名及其与同一名单、事项、轮次、机构的绑定；同一签名者在同一轮的矛盾选票第二张被拒并构成可证明违规 |
| AUTHORIZED_SUBMITTER（受权提交者） | 规则固定一个机构合约或账户为提交者（外部 DAO 投票合约、8033 式 Judge），注册表核验提交者身份、时点与结果落在空间内 | 注册表**不复算**其内部投票，只承认预先指定机构的结果；提交者自身的规则由 policy 引用并固定 |

【R3】三种模式是机构级字段（BodySpec.acceptance），同一规则内不同机构可以不同（用例 B：技术院签名选票、经济院链上计票）。验证承诺不能混同：签名真实不等于没有漏票，"这一批选票的赞成比例"不是"整轮赞成比例"——六张反对已登记后再提交四张赞成签名，不能对新批次算出 100% 赞成；参考实现中后到的批次只是继续计入同一机构实例的票数，机构一旦 Decided 即拒绝新票。首版不实现抽象的万能证明汇总器；任何声称证明"全部有效选票汇总"的扩展必须明确选票集合承诺、数据可用性与完整性依据。EIP-712 本身不提供重放保护，ERC-1271 的有效性可能依赖合约状态，因此防重、接纳时点、合约账户验签以及已接纳选票不得事后失效都由本配置明定。链下签票不放弃注册表的权威：签名只是提交与携带证据的方式，不绕过接纳规则，也不等于另一条链可信任的状态证明。

### 7.6 时钟与截止

规则声明时钟模式（timestamp 或 block number，参考 ERC-6372 的 clock / CLOCK_MODE 做法，默认 timestamp）。所有窗口在受理时换算为绝对时点。截止取"到达制"：选票与结果以在截止前被注册表接收为有效。

### 7.7 隐私扩展边界【已定】

ZK-KYA 可用于"证明满足资格而不披露原始数据"；匿名投票还需防重复投票标识、身份关联策略与验证机制。资格隐私、选票隐私、抗胁迫是不同保证：投票者即使匿名，若仍能向买票者证明自己投了什么，贿选问题并未消失（MACI 把隐私与抗胁迫分开处理）。隐私投票作为扩展支持，不把"采用 ZK"包装成"天然公平"。

---

## 8. 机构组合（规范性可选 profile）【已定进 v1】

"规范性可选"：实现可以不支持；一旦宣称支持，必须遵守明确规则与测试向量。最小形式保留单机构。

### 8.1 组合的对象【已定】

组合的是**机构对同一事项、相容候选效果的决定**，不是无上下文的布尔值。技术院同意支付 10、经济院同意支付 100，不能因为都是 Yes 就合成通过。各机构结果绑定同一 issueId 与同一 effectCandidate；组合规则不能在拿到两个赞成后创造一个双方都没同意过的新效果。

### 8.2 四值语义与组合子【提案】

节点值 ∈ { Pending, Decided(yes), Decided(no), NoDecision(r) }（非二元机构的 Decided 携带结果）。

| 组合子 | Decided(yes) | Decided(no) | NoDecision | Pending |
|---|---|---|---|---|
| ALL(children) | 全部 yes 且绑定同一候选效果 | 任一 no | 无 no、至少一个 NoDecision、无 Pending。原因："所需共同批准未形成"，标注未形成的机构 | 其余 |
| ANY(children) | 任一 yes（可提前结束，其余机构无需等待） | 全部 no | 无 yes、非全部 no、无 Pending | 其余 |
| K-of-M(children) | ≥ K 个 yes 且绑定同一候选效果 | > M − K 个 no（yes 已不可能） | 无 Pending 且上述皆不成立 | 其余 |
| VETO(target, vetoer, window, silence)【R3 修订】 | 【PASS_THROUGH】`now ≥ vetoClose ∧ 窗口内无有效否决 ∧ target 为 yes`；或 vetoer 在窗口内**明确放行**（Decided(no veto)，不可撤回）且 target 为 yes。【REQUIRE_CLEARANCE】vetoer 明确放行且 target 为 yes | vetoer 在窗口内 Decided(veto)，原因 VETOED；或（窗口届满或已放行后）target 为 no | 【REQUIRE_CLEARANCE】窗口届满无放行（NO_CLEARANCE）；或（窗口届满或已放行后）target 为 NoDecision | 窗口未届满且 vetoer 尚无决定——**无论 target 为何**；或 target 仍 Pending |

ALL 与 ANY 是 K-of-M 的特例（M-of-M 与 1-of-M）。VETO 单独表达，因为它带行使人、窗口与沉默语义："审核机构明确否决"与"审核机构一直没回应"不是同一件事。两种沉默制度都可支持，但必须显式选择，不能因为代码把空值当零而无意中选了其中一种。

【R3】仍然有效的否决权、挑战权或必须计入的输入窗口，不能被一次提前 finalize 消灭。12 小时否决窗口、两院在第 1 小时都通过时，剩余 11 小时的否决权不能被架空：VETO 节点在窗口届满或 vetoer 明确决定之前恒为 Pending，settle 必然失败。target = NoDecision 与尚可发生的有效否决之间的优先级由此确定：窗口内的有效否决总是优先，而结果类型是（选票, 时间）的纯函数，与 finalize 的调用顺序无关（见 `test/ACDFComposition.t.sol::test_VETO_result_type_does_not_depend_on_settlement_order`）。

每个组合节点的"形成时点"也是确定的：Yes 形成于第 k 个赞成到达的瞬间，No 形成于第 (M−K+1) 个否决到达的瞬间，NoDecision 形成于最后一个子节点落定的瞬间；VETO 节点形成于否决窗口关闭或 vetoer 决定与 target 落定两者的较晚者。上诉窗口从这个时点起算。

### 8.3 依赖与顺序

机构图有限、无环；节点可声明 after 依赖，其窗口在依赖完成后开启；总时长以最长路径的窗口之和为上限，并计入上诉。上游 NoDecision 使依赖它的下游标记 NoDecision(NOT_REACHED)，原因保留。允许审核、复议等先后关系；反对的是强制所有事项走固定流水线。

### 8.4 标量结果的组合【待定】

【R3 已决】正确抽象是"允许效果的交集"，不是"小一点总安全"。"必须支付 10"与"必须支付 100"是两个不同的精确结果，不能直接取 10；"允许支付不超过 10"与"允许支付不超过 100"在单位、下限与其他约束一致时可以得到共同允许的范围 E_allowed = E_1 ∩ E_2，再按预先声明的选取规则产生结果。形式上是集合交集而不是无条件 min(x_1, x_2)："较小"对付款方有利，对收款方未必合理，没有普适的安全含义。首版 CompositionProfile 只实现二元、同一候选效果的组合（v0.2 参考实现即如此）；标量组合保留为类型化扩展，精确金额与金额上限是不同类型。

---

## 9. 终局、NoDecision 与执行

### 9.1 三维分离【已定】

程序状态、结果类型、执行状态互相独立（第 4 节）。"已终局但 NoDecision"、"同一决定一方执行成功一方失败"都是正常情形。

### 9.2 上诉与终局【已定】

每条配置确定最大上诉轮数（0 轮合法）、总时限、换人规则（如重新抽签并扩员至 2k+1）、上诉资格与押金、最终未能形成决定时如何处置。人类参与的终审体是可选配置，不是框架默认的最高权力；纯 A2A 系统应能在无人介入下完成正常决策。"宪制轨"是某个治理域自己的根规则，不是对全部 Agent 有权的世界最高法院。

### 9.3 NoDecision 的处置【已定】

分开两类语义：

- ACDF 的程序语义：为什么未形成决定、程序何时结束、是否还有合法后续程序。注册表记录。
- 业务应用的处置语义：保持现状、重组、退款、转交、等待原有结算条件。接入合约按**事前承诺**落实，处置引用随事项在受理时冻结。

发起人不得在"未决则退款"与"未决则付款"之间自选；确需立案时分流，只能按预先授权的客观条件，或由获得明确裁量权的机构选择。要禁止的是未经授权的有利选择，不是一切裁量。

### 9.4 执行【已定】

- 可逆性匹配：不可逆效果（资产转移）只接 Final；Provisional 只接可逆或已安排补偿的效果。
- 到达制：受截止约束的动作（尤其拒绝）必须在截止前被目标合约实际接收；凭证声称在截止前形成不足以补救迟到的调用。
- 剩余窗口：受理时检查 **规则最长总时长 + 提交余量 ≤ 接入合约硬截止 − 当前时点**，不是比较原始窗口长度；任务已提交很久才立案，剩余时间可能不足。接入合约有多个相关截止时取较早者（8414：judgmentWindow 约束拒绝，settleBy 约束接受）。参考实现：接入合约把扣除余量后的截止作为 `consumerDeadline` 传入，注册表核验 `admittedAt + maxTotalDuration ≤ consumerDeadline`。
- 【R3】执行失败不反向修改 Final，也不无条件把效果永久标为已执行；失败是否可以重试由目标状态与既定执行规则决定（参考实现：Failed 记录可被后续 Enacted 覆盖，Enacted 不可被 Failed 覆盖）。执行入口可以无许可触发，但调用者只能请求执行已经绑定的效果，不能提供另一个目标地址或任意 calldata。
- 【R3】信息性执行日志只允许绑定的 consumer（或其授权执行模块）报告，按事项、结果、接入方与效果定位，必须记录真实报告者；第三方不能伪报"已执行"，一条失败报告不能覆盖真实的成功记录。
- 防重复：读取凭证可重复，资金动作由接入合约防重。
- 类型匹配：ACDF 可输出"支付 40%"这类标量，但接入一个只接受二元结果的应用时，适配器必须明确映射可支持的结果，不支持的类型在受理时拒绝，不静默转换。

---

## 10. 激励与安全（原则）【已定方向】

激励按依据分开：程序履约（按时提交有效判断、履行已承诺的审阅）可获报酬；可证明的违规（同一轮签署矛盾选票、违反明确承诺的程序义务）可触发处罚；判断质量结合后续可观察结果、可复核证据或独立评估更新，不以多数一致性代替；对尚无客观答案的政策选择，不把"与胜出政策不同"当作信用缺陷。资金激励、信用反馈、二者结合都兼容，内核不强制某种罚没或评分算法。

决策结果进入信用体系的方式：ACDF 输出带规则版本、范围、终局状态与证据引用的结果，由有权限的 KYA scheme 或其他信用系统解释采用。这是可追溯的证据反馈，不是"裁决合约直接改所有人的总信用分"。合理的制裁是暂停某治理域的成员资格、取消某类投票资格，或发布在特定 scheme 下有效的负面断言；这些都不等于销毁对方的身份。

安全考虑清单（ERC Security Considerations 的雏形）：

| 风险 | 处理方向 |
|---|---|
| 女巫 | 信用门槛与运营者上限，并披露剩余信任假设 |
| 贿选与胁迫 | commit-reveal、隐私配置；抗胁迫另有信任模型，不以 ZK 之名承诺 |
| 判断相关性 | 规则声明的独立性处理（6.3） |
| 证据注入 | 证据是数据不是指令；规则可要求理由承诺 |
| 上诉滋扰 | 押金、轮数与总时限上限 |
| 活性 | 截止、无许可 finalize、NoDecision 作为确定终点 |
| 可升级依赖 | 地址 + 代码哈希固定、代理披露管理人 |
| 时间操纵 | 时钟模式声明、提交余量、到达制 |
| 重放 | 签名绑定 chainId、注册表、issueId、轮次、机构实例、policyId、nonce |
| 注册表实例信任 | 接入方绑定具体实例；实例的治理与升级方式须披露 |

---

## 11. 与现有标准的接口

### 11.1 ERC-8414 适配器【已定边界】

- 适配器（`ACDFTaskTenderAdapter`）是任务的 acceptanceAuthority；8414 内核不依赖 ACDF。开案前适配器核验 `acceptanceAuthorityOf(tokenId) == adapter`，并以 ERC-165 **不**声明 ITaskVerifier，确保走判断路径而非机器结算。
- 【R3】按真实 ABI 接入：`submissionOf`、`tenderTermsOf`、`acceptFulfillment`、`rejectFulfillment`（TASK-KERNEL v3.0）。需要判断时任何人可触发 `open(tokenId, submissionId)`，适配器以 CONSUMER_FILED 立案：subject = (chainId, TaskToken, tokenId, dataHash = keccak(submissionId, resultHash, 提交时引用的 taskVersion))；question = 交付是否满足验收标准；outcomeSpace = BINARY{accept, reject}；effectCandidates = {accept → acceptFulfillment, reject → rejectFulfillment}；disposition = 交回任务自身时钟（claimUnjudged）。交付哈希与任务版本被绑定，不能用后来修改的任务说明审判此前已提交的工作。
- 【R3】两类截止都要预留：`T_decision,max + T_margin ≤ min(submittedAt + judgmentWindow, settleBy) − now`（settleBy = 0 视为无此期限）。judgmentWindow 约束 rejectFulfillment，settleBy 约束 acceptFulfillment；只检查 judgmentWindow 时普通接受可能已过 settleBy。这是首版适配器的保守接纳规则，不修改 8414 自身语义。
- 同一提交只能有一个当前有效的事项；已 Decided 的事项不能通过重新立案改判；只有 Final × NoDecision 且剩余时间足够时才允许重新开案。
- Final × Decided(accept 或 reject) 后任何人可触发 `execute(issueId)`，适配器只能调用已绑定的 (任务, tokenId, submissionId) 与结果所隐含的效果；执行前再次核对提交的 resultHash 与 taskVersion。内核拒绝（过 settleBy、过判断窗口、纪元耗尽、权限变更）时记录 Failed，决定不变，目标状态允许时可重试。Final × NoDecision 不调用任务合约，8414 的 claimUnjudged 按其自身规则生效；ACDF 提前记录 NoDecision 不意味着可以提前付款、立即退款或重启任务时钟。
- 标量（部分支付）只在任务内核支持部分结算时才可配置；否则适配器只接受 BINARY 规则。
- 【R3】费用：当前上游规范把内核内的 judgmentFee 列为未来候选，不是本修订已有的字段或支付路径；首版采用独立的陪审费用安排，不假设任务金库会向 ACDF 支付裁决费。

### 11.2 ERC-8183

evaluator 可以是 ACDF 适配器：在 submit 后立案，Final 后调用 complete / reject；expiredAt 必须大于规则最长总时长加余量。核心结算一旦完成，外围上诉不能推翻。

### 11.3 ERC-792 / ERC-1497 仲裁配置

包装合约实现 IArbitrator：createDispute(choices, extraData) 以 CONSUMER_FILED 立案（msg.sender 即 Arbitrable），outcomeSpace = CATEGORICAL(choices)；Final 后回调 rule(disputeId, ruling)；appeal 映射到 ACDF 上诉；arbitrationCost 来自规则费用条款；证据沿用 1497 事件。做有定义、有测试的适配，不宣称"框架够广所以天然兼容"。

### 11.4 ERC-8004 / 8419 / 8434

8004：身份与信誉数据来源；可选桥把 Final 结果有损镜像到 Validation Registry（镜像可滞后、可丢失信息，权威在 ACDF 注册表）。8419：资格规则引用 scheme 与策略；结果作为证据由 scheme 解释。8434：身份锚；ACDF 不改变 AID 状态。

### 11.5 ERC-8033 / 8226

8033 的 Info / Judge 流程可表达为"受权提交者接纳 + 争议轮"的配置。8226 与 ACDF 互补：Agent 的交易授权可规定超额动作需要 ACDF 结果。

---

## 12. 两端测试

验收标准：下面两个用例必须用同一套对象（Policy 版本、Issue 绑定、机构实例、机构决定、Result 的程序状态 × 结果类型、Enactment 记录）与第 4 节的同一个状态机写出来。

### 12.1 用例 A：固定名单 3-of-5 验收一笔 8414 交付

| 对象 | 实例 |
|---|---|
| Policy P_A v1 | eligibility = ROSTER(5 地址)；selection = 全体；weight = 等权；outcomeSpace = BINARY；aggregation = K-of-N(K=3；3 票否决即 Decided(no))；composition = 单机构；timing = 投票窗口 24h，timestamp 钟；appeal = 0；termination = 截止未达阈值 → NoDecision；resultAcceptance = ON_CHAIN_TALLY；dependencies = 无；update = 任务创建者地址；emergency = 无；instantiable = 无 |
| Issue I_A | policyId = P_A v1；subject = (TaskToken, taskId, submissionId, deliverableHash)；question = 交付是否满足验收标准；outcomeSpace = BINARY{accept, reject}；effectCandidates = {accept → acceptFulfillment, reject → rejectFulfillment}；bindings = [Adapter8414, CONSUMER_FILED]；effectClass = Binding；disposition = 交回任务时钟；filer = Adapter8414；deadlines = consumerDeadline = min(submittedAt + judgmentWindow, settleBy) − 余量，受理时检查 admittedAt + maxTotalDuration ≤ consumerDeadline；snapshot = 名单 5 人等权 |
| Body B1 | 名单机构，一轮 |
| 主路径 | Filed → Deciding（原子受理）；3 票 accept 上链 → B1 Decided(accept) → 无上诉窗口 → Final × Decided(accept) → 适配器在窗口内调用 acceptFulfillment → Enactment(Adapter8414, accept) = Enacted |
| 变体 1 | 3 票 reject → B1 Decided(reject) → Final × Decided(reject) → 适配器在窗口内调用 rejectFulfillment |
| 变体 2 | 截止时 2 票 accept、1 票 reject → B1 NoDecision(QUORUM_NOT_MET) → Final × NoDecision → 适配器不调用；8414 的 claimUnjudged 按其规则生效 |

### 12.2 用例 B：Swarm 章程下的重大参数变更

| 对象 | 实例 |
|---|---|
| 授权 | 治理合约 G 登记 STANDING_ACCEPTANCE：事项类别 PARAM_CHANGE；标的 = 参数集 X 且新值在允许区间；接受规则族 F_B 中由 G 的宪制程序发布的版本；立案人 = 任何成员；disposition = NoDecision → 保持现状；效果由 G 授权的执行模块 E（48h 时间锁）落实；有效期与上限声明 |
| Policy P_B v3 | composition = VETO(target = ALL(Tech, Econ), vetoer = Screening, window = 12h, silence = PASS_THROUGH)。Screening：资格 = 元老院名单，聚合 = K-of-N。Tech：资格 = 信用合格 Agent 配置（8434 Active + 8419 scheme "contract-audit" ≥ 3），selection = SORTITION k=9 且每运营者 ≤ 2，weight = 等权，aggregation = {q = 2/3, a = 2/3, 确认期 6h}，resultAcceptance = VERIFIED_AGGREGATE。Econ：资格 = 持仓 ≥ s 的成员且 8434 Active，selection = OPEN，weight = 持仓加权且每运营者 ≤ 10%，aggregation = {q = 40%, a(τ) 由 100% 线性降至 50% 跨 72h, s = 25%, 确认期 12h}，resultAcceptance = ON_CHAIN_TALLY。appeal = 1 轮，上诉人 = 任何成员 + 押金，换人规则 = Tech 重新抽签 k=19、Econ 重投；总时长上限 10 天；dependencies = 抽签随机源与资格核验器以地址 + 代码哈希固定；update = F_B 的新版本须经规则 P_const 下的 ACDF 决定；emergency = G 的监护人可暂停新立案，不触碰在审事项 |
| Issue I_B | policyId = P_B v3；subject = (G, paramId, newValue)；question = 是否采纳新值；outcomeSpace = BINARY{adopt, reject}；effectCandidates = {adopt → E.schedule(setParam(X, v))}；bindings = [G, STANDING_ACCEPTANCE(ref)]；effectClass = Binding；disposition = 保持现状；filer = 成员 M；snapshot = Tech 候选池与抽签结果、Econ 票权 |
| Bodies | Screening、Tech、Econ 各一实例；上诉后 Tech、Econ 新实例 |
| 主路径 | Filed → Deciding（对照常设接纳核验并快照，原子受理）；Screening 12h 内无否决 → PASS_THROUGH；Tech 与 Econ 并行，分别 Decided(adopt)；ALL 合成 Decided(adopt) → Provisional × Decided(adopt)，上诉窗口 48h → 成员提出上诉并缴押金 → Deciding 第 2 轮 → 新实例分别 Decided(adopt) → 达最大轮数 → Final × Decided(adopt) → E 读取结果、核验后 schedule → 48h 后 E 执行 → Enactment(E, adopt) = Enacted |
| 变体 1 | Screening 在窗口内 Decided(veto) → VETO 合成 Decided(reject，原因 veto) → Provisional → 无上诉 → Final × Decided(reject) → 无效果 |
| 变体 2 | Tech Decided(adopt)，Econ 截止时参与 35% < 40% → Econ NoDecision(QUORUM_NOT_MET) → ALL 合成 NoDecision("所需共同批准未形成"，标注 Econ) → Final × NoDecision → 保持现状；Tech 的 adopt 仅作为记录与证据存在 |

### 12.3 对照

两个用例使用完全相同的对象与迁移。用例 A 的 composition 是单机构、appeal = 0、CONSUMER_FILED、ON_CHAIN_TALLY；用例 B 的 composition 是 VETO over ALL、appeal = 1、STANDING_ACCEPTANCE、混合接纳模式。差异全部落在 Policy 的组件取值与 Issue 的 bindings 上，状态机与 Result 的二维结构不变。

【R3】措辞降格：本节是**两个设计用例已展开**，不是"两端测试通过"。可执行的对应物在 v0.2 参考实现中：用例 A 由 `test/ACDFAdapter8414.t.sol` 对接**真实的** TASK-KERNEL v3.0 `TaskToken`（vendored 夹具，源码提交 `306a8f40`）运行接受、拒绝、NoDecision→claimUnjudged、迟到执行、纪元耗尽后重试等路径；用例 B 由 `test/ACDFCaseB.t.sol` 运行主路径、否决、经济院未达门槛、上诉轮未决保留原决定等路径。用例 B 的测试使用**固定资格快照与确定性夹具**，证明的是机构组合、上诉与绑定机制正确；它不验证信用核验、抗女巫或随机抽签。真正的"测试通过"还需接实际 Sepolia 实例并记录合约地址、源码版本、运行时代码、交易与断言结果。

---

## 13. v1 配置清单

【R3】区分"标准预留了接入方式"（Planned / Reserved）与"这个配置已经有可验证实现"（Implemented）。首版只对 Implemented 声称合规实现。

| 配置 | 性质 | 内容 | v0.2 状态 |
|---|---|---|---|
| Minimal K-of-N | MUST | 固定名单、等权、K-of-N、单机构、0 上诉、链上计票（7.2） | Implemented（`ACDFRegistry` 内置 ROSTER_KOFN + ON_CHAIN_TALLY；83 条真值表向量） |
| Body Composition | 规范性可选 | ALL / ANY / K-of-M / VETO、四值语义、顺序依赖（第 8 节） | Implemented（二元、同一候选效果；并行机构 + VETO 窗口；192 条真值表向量）。顺序依赖（after）、标量组合：Planned |
| Signed Ballot | 规范性可选 | EIP-712 选票批量接纳、ERC-1271 合约账户、与链上计票同语义（7.5） | Implemented（SIGNED_BALLOTS 机构）。结果凭证的签名携带：Planned |
| Authorized Submitter | 规范性可选 | 受权提交者机构（8033 式 Judge、外部 DAO 投票）（7.5） | Implemented（AUTHORIZED_SUBMITTER 机构） |
| Appeals | 规范性可选 | 有限轮、全体机构重建、结果类型可上诉掩码、上诉未决保留原决定（9.2） | Implemented |
| ERC-8414 Adapter | 适配器 | 真实 ABI、两类截止、一义务一事项、失败记录与重试（11.1） | Implemented（`ACDFTaskTenderAdapter`，对接真实 TaskToken 夹具） |
| Credit-Qualified Agent | 规范性可选（Finch 默认） | 严格绑定 8419 / 8434 的资格完整核验语义（6.1） | Planned（资格快照生成方式待定，6.4） |
| Sortition | 规范性可选 | 可验证随机抽取、加权抽取、扩员规则（6.2） | Planned（随机源待定） |
| Arbitration（792 / 1497） | 规范性可选 | IArbitrator 适配、Case / Ruling 术语（11.3） | Planned（1497 式 Evidence 事件已实现） |
| Executor | 规范性可选 | 受权执行模块、执行延迟、防重复（9.4） | Planned（v0.2 由接入合约或适配器直接落实） |
| Optimistic / Challenge | 规范性可选 | 默认结果 + 挑战资格 + 窗口 + 升级规则（P7） | Reserved |
| Privacy | 规范性可选 | ZK 资格证明、匿名选票、防重复标识；不承诺抗胁迫（7.7） | Reserved |
| Fees / Bonds | 规范性可选 | 立案押金、参与押金、上诉押金、程序报酬 | Reserved（v0.2 无资金流） |
| Cross-chain | 延后 | 单独披露链终局与桥的信任假设 | Reserved |

---

## 14. 决定记录与待决清单

### 14.1 已决（R0 = Gary 原始要求，R1 / R2 = 顾问两轮评审，R3 = 顾问实现审查）

| # | 决定 | 来源 |
|---|---|---|
| 1 | 标题 Agent Collective Decision Framework；中文「Agent 集体决策框架」，交流简称「Agent 合议机制」；仲裁为 profile | R1 |
| 2 | 一个框架 ERC：最小内核 + 规范性可选 profile；初期不拆成一组 ERC | R1 |
| 3 | 授权先于资格；表决不创造权限、不证明真理 | R1 |
| 4 | 核心规则对象 Decision Policy；授权关系 Authorization；不设 Mandate 对象 | R2 |
| 5 | 注册表为规范记录源；接入合约为受约束的效力落实方；只有外围副本是镜像 | R2 |
| 6 | 核心不内置通用资产执行器；Executor 可选；程序状态 / 结果类型 / 执行状态三维分离 | R2 |
| 7 | v1 含规则更新权限与版本语义；不含完整授权树、递归委托、共享额度 | R2 |
| 8 | 链上注册与正式结果标识为核心；712 / 1271 为可选扩展；不宣称天然跨链 | R2 |
| 9 | 机构组合进 v1，规范性可选；四值语义；VETO 带时间语义 | R2 |
| 10 | NoDecision 事前约定、事项绑定、接入方落实；发起人不得自选 | R2 |
| 11 | 资格规则为硬要求；8419 / 8434 构成信用合格 Agent 配置，不是框架硬依赖 | R1 |
| 12 | 资格、选取、权重三分；资格与事项领域绑定 | R1 |
| 13 | 权重与独立性声明规范化、算法开放；控制权 / 判断相关 / 利益关联三问题分开 | R1 |
| 14 | 有限上诉、明确终局；人类终审可选；NoDecision 合法 | R1 |
| 15 | 不以多数一致定义正确；结果作为证据进 KYA，不直接改信用；不触碰 AID 生命周期 | R1 |
| 16 | 8414 走适配器，不反向依赖；时间语义相容，按剩余窗口与到达制检查 | R1 / R2 |
| 17 | 机械验证不是投票；乐观确认不是 θ=0 | R1 |
| 18 | Polkadot 借鉴范围：权力分工、授权来源、制度可修改性、双门限曲线；不借鉴网络安全角色拼成的流水线 | R1 |
| 19 | 不宣称空白；对比 8033 / 8183 / 792 | R1 |
| 20 | K-of-N 为最小配置与理论基础；0-of-0 与 1-of-1 作为直观比喻，规范中分别对应验证器路径与单机构单成员 | R0 / R1 |
| 21 | A 接纳模式：三种模式与 Binding / Advisory 通过；POST_ACK 改为先立案、后确认、再受理，确认在投票前，Advisory 不得升级 | R3 |
| 22 | B 最小 K-of-N：互补阈值与禁止改票通过；明确为"批准提案"语义，no = 该提案被阻止，不是对相反命题的认定 | R3 |
| 23 | C 结果接纳：三种模式进入 v1 规范设计、非全部强制；绑定到机构而非整份规则；受权提交不等于注册表验证了全部选票 | R3 |
| 24 | D 可实例化参数：预声明参数与设定权限通过；设定者由规则与授权关系确定，不一律限定为 consumer；Advisory 也须有合法设定路径 | R3 |
| 25 | E 依赖固定：地址 + 代码哈希 + 管理员白名单不足以证明冻结；首版采用不可升级内核 + 固定版本模块 + 与规则绑定的执行配置；规则哈希绑定全部执行参数 | R3 |
| 26 | F 标量组合：允许未来支持预声明的允许效果集合交集，不接受通用 min()；首版组合只做二元、同一候选效果 | R3 |
| 27 | G 撤回：默认只允许在 Filed 阶段单方撤回；受理后共同撤销只能是预声明扩展 | R3 |
| 28 | H 时钟：timestamp 默认；一个注册表实例一种时钟；不以区块数换算秒数 | R3 |
| 29 | I 执行日志：可选信息性日志，仅绑定 consumer 或获授权 Executor 可报告，记录真实报告者，失败不覆盖成功 | R3 |
| 30 | J 简称：ACDF，不再待定 | R3 |
| 31 | K 文件与目录：本地命名通过；提交版本由脚本生成，9999 只是工作占位，提交包只转换路径与编号、不删规范性约束 | R3 |
| 32 | Final 为真正终局，不被后续轮次取代；Deciding→Final 条件为"不存在剩余合法后续程序"；NoDecision 可上诉时先进 Provisional | R3 |
| 33 | 【新增决定】上诉轮未形成决定时保留最近一个有效实体决定，NoDecision 单独记录；Result 记录 sourceRound 与 roundCount；上诉重建全部机构 | R3 |
| 34 | VETO 在否决窗口内不得提前放行；有效否决优先；结果类型与 finalize 调用顺序无关 | R3 |
| 35 | 时间：冻结计算规则（初始时点、总硬截止、阶段时长、启动条件），上诉窗口从结果形成时点起算；超时处置覆盖全部非终局状态 | R3 |
| 36 | 8414 适配：真实 ABI；两类截止取较早者；绑定 resultHash 与引用的 taskVersion；一义务一事项；无 judgmentFee 假设；执行失败记录 Failed、不改 Final | R3 |
| 37 | 未完成的 profile 标为 Planned / Reserved，首版不声称已实现；两个叙述性用例不称"测试通过" | R3 |

### 14.2 待决（进入 ERC 文本前）

| # | 事项 | 现状 | 位置 |
|---|---|---|---|
| A' | 多接纳方事项 | v0.2 每事项一个 consumer；必要接纳集合及完成条件作为扩展，需定义受理时的检查方式 | 5.3 |
| B' | 可实例化参数的具体机制 | v0.2 规则固定全部机构与窗口；按客观属性分级（金额→面板规模）的实例化规则需定义设定者与范围表达 | 3.2 |
| C' | 顺序依赖（after） | v0.2 全部机构并行启动，VETO 以窗口表达审核；审核→复议的显式先后依赖需定义窗口开启语义与总时长计算 | 8.3 |
| D' | 标量组合的类型化扩展 | 精确金额 vs 金额上限两种类型的交集规则 | 8.4 |
| E' | 结果凭证的签名携带 | 链上记录已是核心；EIP-712 结果凭证只作携带，需定义与注册记录的对应与"不构成跨链证明"的措辞 | 7.5 |
| F' | 费用与押金 | 立案押金、参与押金、上诉押金、程序报酬的归属与分配 | 10 |
| G' | 资格快照生成方式与随机源 | 信用合格 Agent 配置与抽签配置的前提 | 6.4 |

后续回合再展开：隐私配置细则、Advisory 事项的押金规则、Executor 的延迟与撤回语义、792 适配器的 Case / Ruling 映射。

---

## 15. 下一回合与仓库布局

### 15.1 本回合已交付（v0.2）

- 参考实现：`ACDFPolicyRegistry`（规则族与版本、结构校验、内容寻址）、`ACDFRegistry`（常设接纳、三种接纳模式、链上计票、签名选票、受权提交者、四值组合、VETO 窗口、轮次与上诉、终局与硬截止、信息性执行日志、1497 式证据事件、ERC-6372 时钟）、`ACDFTaskTenderAdapter`（8414 适配器）。见 `assets/erc-acdf/contracts/`。
- 测试：`test/` 下 8 个套件 117 个测试，覆盖顾问要求的六组最低集合（最小计票、接纳与冻结、组合、轮次与终局、规则与验证、8414 执行）以及用例 B 的可执行版本；8414 测试对接 vendored 的真实 TaskToken（task-token-standard 提交 `306a8f40`）。记录见 `docs/test-record.md`。
- 向量：`assets/erc-acdf/vectors/`（policy-id、ballot-digest 由 ethers v6 生成并在 Solidity 中复核；kofn-tally 83 条、composition 192 条真值表由 JS 独立实现规则生成并在 Solidity 中逐条复核）。
- schemas：`policy-spec.schema.json`、`result-receipt.schema.json`。

### 15.2 下一回合产出

- `ERCS/erc-acdf.md` 英文文本：Abstract / Motivation / Specification（以 v0.2 的对象、状态机与接口为基础，区分 MUST 内核与规范性可选 profile）/ Rationale / Backwards Compatibility / Security Considerations；提交包由脚本生成 9999 工作占位版本。
- Sepolia：部署 ACDFPolicyRegistry + ACDFRegistry + 适配器，对接真实的 8414 Sepolia 合约（TaskToken 0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7）跑用例 A，并记录合约地址、源码版本、运行时代码、交易与断言结果；有真实执行证据后才把"设计用例"升级为"测试通过"。
- 14.2 的 A'–G' 拍板；Planned profile 中优先信用合格 Agent 配置（需先定资格快照生成方式）。
- Magicians 帖草稿（docs/magicians-post.md）。

节奏沿用 8414 / 8419 / 8434：仓库先、Magicians 帖、填 `discussions-to`、从 ethereum/ERCs master 新建分支 `add-erc-acdf`（绝不从 fork 的 master 切）、PR。资产链接按已知规则写 `../assets/eip-NNNN/`。

### 15.3 仓库布局（沿用 task-token-standard / kya-standard / aid-standard 的结构）

```
acd-framework/
├── README.md
├── foundry.toml                   # solc 0.8.24, via-IR, optimizer runs 1（注册表 23.4 KB，EIP-170 之内）
├── package.json                   # ethers 6.17.0，仅用于生成向量
├── docs/
│   ├── design-memo-zh.md          # 本文（v0.2）
│   ├── test-record.md             # 测试记录
│   └── magicians-post.md          # 下一回合
├── ERCS/
│   └── erc-acdf.md                # 下一回合；提交时由脚本生成 9999 工作占位版本
├── assets/erc-acdf/
│   ├── contracts/
│   │   ├── ACDFTypes.sol
│   │   ├── ACDFPolicyRegistry.sol
│   │   ├── ACDFRegistry.sol
│   │   ├── interfaces/            # IACDFPolicyRegistry, IACDFRegistry, ITaskTender8414
│   │   ├── libraries/             # SignatureChecker (ECDSA + ERC-1271)
│   │   └── adapters/              # ACDFTaskTenderAdapter
│   ├── schemas/                   # policy-spec, result-receipt
│   └── vectors/                   # policy-id, ballot-digest, kofn-tally, composition
├── test/                          # Foundry 测试；fixtures/task-token/ 为 vendored 的真实 8414 合约
├── tools/                         # vectors.js
├── scripts/                       # 下一回合：Sepolia 部署
└── deployments/
```

---

## 16. 参考实现 v0.2 与测试记录（摘要）

工具链：Foundry forge 1.5.1-stable，solc 0.8.24，via-IR，optimizer runs 1。运行时大小：ACDFPolicyRegistry 9,545 B，ACDFRegistry 23,400 B（EIP-170 上限 24,576 B），ACDFTaskTenderAdapter 5,728 B。

| 顾问要求的测试组 | 套件 | 覆盖 |
|---|---|---|
| 最小计票 | `ACDFMinimal.t.sol`（25）+ `ACDFVectors.t.sol::test_kofn_tally_vectors`（83 行） | 1-of-1、K=1、K=N、互补否决阈值、截止未决、重复成员、重复票、迟到票、非法门槛、决定时点、规则哈希与执行参数一致、族版本 |
| 接纳与冻结 | `ACDFAdmission.t.sol`（21） | 未授权绑定、常设接纳的立案人 / 规则 / 标的 / 议题约束、撤销只阻新案、POST_ACK 投票前确认、Advisory 升级尝试、受理后改参数无路径、受理后单方撤回被拒、同一义务重复立案、消费者截止检查、证据事件 |
| 组合 | `ACDFComposition.t.sol`（23）+ `ACDFVectors.t.sol::test_composition_vectors`（192 行） | ALL / ANY / K-of-M 的 Pending 与 NoDecision；VETO 截止前不得放行、明确放行、有效否决、迟到否决、REQUIRE_CLEARANCE 沉默、结果类型与调用顺序无关；受权提交者越权、沉默、重复；重复子节点、回边、不在树中、空图、非法 k、机构类型与接纳模式不匹配、总时长覆盖 |
| 轮次与终局 | `ACDFRounds.t.sol`（13）+ `ACDFCaseB.t.sol`（5） | 上诉耗尽、对 NoDecision 上诉、上诉未决保留前结果、旧轮签名重放、Final 不可替换、窗口从形成时点起算、Provisional / Deciding 的硬截止路径、上诉资格 |
| 规则与验证 | `ACDFSigned.t.sol`（10）+ `ACDFVectors.t.sol`（policy-id、ballot-digest） | 伪造 / 错配签名、高 s 与非法 v、同一投票人两票与矛盾签名、非成员签名、批次形状、迟到签名、ERC-1271 合约账户、后到批次不能改写已决机构、EIP-712 域绑定、跨语言编码一致 |
| 8414 执行 | `ACDFAdapter8414.t.sol`（16） | 两类截止、权限不匹配、非 Pending 与机器路径（夹具）、一义务一事项与不改判、NoDecision 后重开、接受路径真实付款、拒绝路径释放预留、NoDecision 不触发业务默认结算、纪元耗尽失败后重试、迟到执行被内核拒绝后默认结算接管、任务版本更新不改变被审版本、重复执行 |

合计 8 个套件 117 个测试全部通过；完整列表与命令见 `docs/test-record.md`。两个局限必须如实说明：用例 B 使用固定资格快照与确定性夹具；8414 对接的是 vendored 夹具而非 Sepolia 实例，链上证据留待下一回合。

---

## 附录 A　术语表（中英对照，供 ERC 文本统一用词）

| English | 中文 | 说明 |
|---|---|---|
| Agent Collective Decision Framework (ACDF) | Agent 集体决策框架 | 正式名 |
| Decision Policy | 决策规则 | 版本化、内容寻址的规则模板 |
| Policy Family | 规则族 | 版本之间的关联与更新权限的归属 |
| Policy Version / policyId | 规则版本 | 不可变 |
| Authorization | 授权 | 接入合约对接受何种结果与效果的承诺 |
| Consumer (relying contract) | 接入合约 | 承诺接受结果并落实效果的一方 |
| Standing Acceptance | 常设接纳 | 接入合约预先登记的接纳声明 |
| Acknowledgment | 事后确认 | POST_ACK 模式下接入合约的确认 |
| Binding | 绑定 / 接纳关系 | 事项与接入合约之间已核验的关系 |
| Issue | 事项 | 一次具体决策的绑定对象 |
| Subject | 标的 | 被决定的对象 |
| Question | 议题 | 针对标的提出的具体问题 |
| Outcome Space | 结果空间 | 答案的集合或区间 |
| Effect Candidate | 候选效果 | 每个结果对应的接入合约动作 |
| Effect Class (Binding / Advisory) | 效力类别 | 有接纳 / 无接纳 |
| Disposition | 处置 | NoDecision 时接入方的既定后果 |
| Filer | 立案人 | — |
| Admission | 受理 | 核验与冻结完成 |
| Snapshot | 快照 | 受理时固定的资格与权重 |
| Body | 机构 | 资格 + 选取 + 权重 + 聚合的组合 |
| Body Instance | 机构实例 | 某事项某轮上的机构 |
| Body Decision | 机构决定 | Pending / Decided / NoDecision |
| Ballot | 选票 | — |
| Eligibility | 资格 | 谁可进候选池 |
| Selection | 选取 | 本次由谁参与 |
| Weight | 权重 | 意见如何计入 |
| Aggregation / Pass Rule | 聚合 / 通过规则 | — |
| Participation Threshold (quorum) | 参与门槛 | q |
| Approval Ratio | 赞成比例 | a |
| Support Ratio | 支持比例 | s |
| Confirmation Period | 确认期 | 条件须持续成立的时长 |
| Composition | 机构组合 | — |
| Combinator (ALL / ANY / K-of-M / VETO) | 组合子 | — |
| Veto Window | 否决窗口 | — |
| Round | 轮次 | roundCount = 最后尝试的轮次 |
| Source Round | 采用轮次 | sourceRound = 最终采用决定的轮次，可与 roundCount 不同 |
| Obligation Key | 义务键 | keccak256(consumer, subject, question)；同一义务只能有一个未终局的 Binding 事项 |
| Appeal | 上诉 | — |
| Procedure State | 程序状态 | Filed / Deciding / Provisional / Final / Withdrawn |
| Outcome Type | 结果类型 | None / Decided / NoDecision |
| Decided / NoDecision | 已决 / 未决 | — |
| Provisional / Final | 初步 / 终局 | — |
| Result | 正式结果 | 程序状态 × 结果类型 |
| Enactment / Enactment Record | 执行 / 执行记录 | 权威在接入合约 |
| Result Acceptance Mode | 结果接纳模式 | 正式结果进入注册表的方式 |
| Evidence | 证据 | ERC-1497 事件 |
| Executor | 执行模块 | 受权、带延迟的可选 profile |
| Adapter | 适配器 | 连接 8414 / 8183 / 792 等 |
| Profile | 配置 | 规范性可选 |
| Minimal Profile | 最小配置 | MUST |
| Credit-Qualified Agent Profile | 信用合格 Agent 配置 | 严格绑定 8419 / 8434 |
| Arbitration Profile | 仲裁配置 | 792 / 1497 兼容；Case / Ruling 术语 |
| Clock | 时钟 | ERC-6372 式声明 |
| Charter / Grant | （保留词） | 组织章程型常设接纳 / 具体权限授予记录；不作核心对象 |

---

## 附录 B　v0.2 参考实现接口（非规范，ERC 文本阶段再定稿）

两个共部署的注册表 + 一个适配器。字段与命名以 `assets/erc-acdf/contracts/` 为准。

```solidity
interface IACDFPolicyRegistry {
    function policyIdOf(PolicySpec calldata spec) external pure returns (bytes32);   // keccak256(abi.encode(spec))
    function registerPolicy(PolicySpec calldata spec) external returns (bytes32 policyId);
    function policyExists(bytes32) external view returns (bool);
    function familyAuthority(bytes32 family) external view returns (address);
    function familyLatest(bytes32 family) external view returns (bytes32 policyId, uint32 version);
    function roundDurationOf(bytes32) external view returns (uint64);
    function timingOf(bytes32) external view returns (Timing memory);
    function policyHeader(bytes32) external view returns (bytes32 family, uint32 version, bytes32 previous, address updateAuthority, bytes32 descriptorHash);
    function bodyCount(bytes32) external view returns (uint256);
    function bodyOf(bytes32, uint32 body) external view returns (BodySpec memory);
    function nodeCount(bytes32) external view returns (uint256);
    function nodeOf(bytes32, uint32 node) external view returns (Node memory);
}

interface IACDFRegistry {
    function policies() external view returns (IACDFPolicyRegistry);
    // 授权
    function registerStandingAcceptance(StandingAcceptanceInput calldata) external returns (bytes32 acceptanceId);
    function revokeStandingAcceptance(bytes32 acceptanceId) external;
    // 事项
    function file(IssueInput calldata) external returns (bytes32 issueId);            // CONSUMER_FILED / STANDING 原子受理；POST_ACK 停在 Filed
    function acknowledge(bytes32 issueId, bytes32 effectYes, bytes32 effectNo, bytes32 disposition, uint64 consumerDeadline) external;
    function admitAdvisory(bytes32 issueId) external;
    function expireUnacknowledged(bytes32 issueId) external;
    function withdraw(bytes32 issueId) external;                                      // 仅 Filed、仅立案人
    function submitEvidence(bytes32 issueId, string calldata evidenceURI) external;    // 1497 式事件
    // 表决（按机构的接纳模式分流）
    function castBallot(bytes32 issueId, uint32 body, bool approve) external;
    function submitSignedBallots(bytes32 issueId, uint32 body, address[] calldata voters, bool[] calldata approves, bytes[] calldata signatures) external;
    function submitBodyResult(bytes32 issueId, uint32 body, NodeStatus status) external;
    // 轮次与终局
    function settleRound(bytes32 issueId) external;      // 根节点非 Pending 时登记本轮结果 → Provisional 或 Final
    function appeal(bytes32 issueId) external;           // 窗口内、有资格者；重建全部机构
    function finalize(bytes32 issueId) external;         // 上诉窗口届满
    function enforceHardDeadline(bytes32 issueId) external;
    // 执行日志（信息性；仅绑定的 consumer）
    function recordEnactment(bytes32 issueId, bytes32 effectId, EnactmentStatus status, bytes32 ref) external;
    // 读取
    function getResult(bytes32 issueId) external view returns (Result memory);        // 程序状态 × 结果类型 + sourceRound
    function getIssue(bytes32 issueId) external view returns (Issue memory);
    function getRound(bytes32 issueId, uint32 round) external view returns (RoundState memory);
    function getBodyState(bytes32 issueId, uint32 round, uint32 body) external view returns (BodyState memory);
    function bodyStatus(bytes32 issueId, uint32 round, uint32 body) external view returns (NodeStatus, Reason, uint64 at);
    function nodeStatus(bytes32 issueId, uint32 round, uint32 node) external view returns (NodeStatus, Reason, uint64 at);
    function hasVoted(bytes32 issueId, uint32 round, uint32 body, address voter) external view returns (bool);
    function activeIssueOf(address consumer, bytes32 obligationKey) external view returns (bytes32);
    function obligationKeyOf(address consumer, Subject calldata subject, bytes32 question) external pure returns (bytes32);
    function getEnactment(bytes32 issueId, address consumer, bytes32 effectId) external view returns (Enactment memory);
    function ballotDigest(bytes32 issueId, uint32 round, uint32 body, address voter, bool approve) external view returns (bytes32);
    function clock() external view returns (uint48);         // ERC-6372
    function CLOCK_MODE() external view returns (string memory);
}

contract ACDFTaskTenderAdapter {          // ERC-8414 acceptanceAuthority backed by one ACDF policy
    function open(uint256 tokenId, uint256 submissionId) external returns (bytes32 issueId);  // permissionless trigger; adapter files as consumer
    function execute(bytes32 issueId) external;                                             // Final × Decided → acceptFulfillment / rejectFulfillment
}
```

状态机（v0.2）：`Filed → Deciding → (Provisional ⇄ Deciding)* → Final`，另有 `Filed → Withdrawn`。结果类型 `None / Decided / NoDecision` 与执行状态 `NotEnacted / Enacted / Failed` 独立记录。

---

## 附录 C　借鉴对照

| 来源 | 借什么 | 落在哪 | 不借什么 |
|---|---|---|---|
| Polkadot OpenGov | Origins / Tracks 的"按客观属性分级"；Approval / Support 双门限与确认期；Fellowship 式元老院；制度可修改性 | 3.2 instantiable、7.3、8.2 VETO、5.5 | Collator / Validator / Nominator / Fisherman 作为治理流水线（Fisherman 已被官方放弃） |
| Polkadot NPoS | 提名者与被提名者共担罚没的责任设计 | 6.2 担保（带范围、期限、上限、触发条件） | 无限信用出借 |
| Kleros | 抽签、上诉扩员（2k+1）、792 / 1497 接口 | 6.2 SORTITION、9.2、11.3 | "与多数一致即正确"的激励默认 |
| OpenZeppelin Governor / Timelock | 决策与执行分离；执行延迟 | 9.4、Executor profile | 把代币加权当唯一权重 |
| Safe | 固定名单 K-of-N | 7.2 最小配置 | — |
| UCAN / Zodiac / AccessManager | 衰减式授权、受权执行模块、带延迟的角色权限 | 5.4 非扩张、Executor profile | 完整授权树进 v1 内核 |
| ERC-8033 | 受权提交者聚合 + 争议轮 | 7.5 AUTHORIZED_SUBMITTER | 单一 Judge 作为框架默认 |
| ERC-8419 KYA | 注册表 + 描述 JSON；权威注册表 + 有损镜像桥的分工 | 3.2、11.4 | 把注册表降格为镜像 |
| MACI | 隐私与抗胁迫分开处理 | 7.7 | 以 ZK 之名承诺抗胁迫 |
