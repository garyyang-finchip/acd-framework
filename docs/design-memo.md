# Agent Collective Decision Framework (ACDF) — Design Memo

| | |
|---|---|
| Version | v0.2 (incorporates the third review round; matches reference implementation v0.2) |
| Date | 2026-10-04 |
| Nature | Design memo and implementation specification. The objects, state machine and interfaces of v0.2 are realized by the reference implementation under `assets/erc-acdf/contracts/` and the 129 tests under `test/`. This is not yet the ERC text. |
| Repository | `acd-framework` · this file: `docs/design-memo.md` |
| Authors | Gary Yang (FinChip), drafted with Claude; three rounds of advisor review incorporated |

**Tags used in this document**

- **[Decided]** — settled in the discussion rounds; not reopened by later text
- **[Proposed]** — introduced by this memo and adopted at implementation review
- **[Open]** — direction settled, details deferred
- **[R3]** — corrections or new decisions from the third (implementation) review; new in v0.2

**Summary of v0.2 changes relative to v0.1 (R3).** POST_ACK becomes "file, then acknowledge, then admit": acknowledgment must precede admission and voting, and an Advisory issue can never be upgraded to Binding. No unilateral withdrawal after admission. The result-acceptance mode is a property of a body, not of a whole policy. Final is terminal and is never replaced by a later round; Deciding → Final requires "no remaining legal procedure". New decision: when an appeal round ends without a decision, the most recent substantive decision is kept. A VETO cannot be bypassed by early settlement while its window is open. The policy hash binds every execution parameter (`policyId = keccak256(abi.encode(PolicySpec))`); the first version uses a non-upgradeable kernel with built-in, fixed-version body kinds. ERC-8414 integration uses the real ABI, both 8414 clocks (judgment window and `settleBy`) and the existing fee mechanics, with no `judgmentFee` assumption. "Two-ends test passed" is downgraded to "two design cases worked out"; executable tests live in `test/`.

---

## 0. What this document is

This memo fixes the principles settled over three discussion rounds, gives an object model and state semantics under which the simplest fixed-roster K-of-N and the most complex multi-body configuration are expressible with the same objects, and lists what must still be decided before the ERC text.

Reading order: sections 1–2 for positioning and principles; sections 3–4 are the core (objects and states); sections 5–9 develop each layer; section 12 holds the two worked cases; section 14 is the decisions log and open-items list; section 16 summarizes the reference implementation and tests.

---

## 1. Positioning

### 1.1 One-sentence definition [Decided]

> ACDF lets qualified participants, within explicit authorization and under verifiable, composable rules, form collective decisions with defined effect.

In four clauses [Decided]: **decision policies organize the deliberating bodies; authorization bounds the effect; the registry holds the normative record; adapters connect to execution.**

### 1.2 Naming [Decided]

| Where | Name |
|---|---|
| ERC title | Agent Collective Decision Framework |
| Abbreviation | ACDF ("CDF" collides with the statistical term, "ACD" with the call-center term) |
| Dispute-handling application | Arbitration Profile |

Not adopted: "AI Arbitration" (locks the framework into the dispute scenario and carries a specific legal meaning), "Agent Adjudication" (judicial vocabulary, reserved for the arbitration profile), "Agent Governance Framework" (broader than what the specification actually covers: it does not govern membership management, treasury, organizational continuity or execution scheduling).

The general layer avoids judicial vocabulary: Issue, Decision, Result. Case and Ruling appear only inside the arbitration profile.

### 1.3 What it is, what it is not

ACDF is a minimal interoperable kernel for collective decisions, plus a set of normative-optional profiles.

It is not: an arbitration system (arbitration is one profile); a complete governance system; a delegated-authority protocol (authorization is a constraint, not the subject); a credit system (credit is expressed by ERC-8419 / ERC-8434 / ERC-8004 — ACDF consumes eligibility conditions and produces evidence); an executor (external effects are enforced by relying contracts or authorized executor modules).

### 1.4 Place in the standards family [Decided]

| Standard | Role | Relation to ACDF |
|---|---|---|
| ERC-8434 AID | Identifies the subject | Identity anchor for eligibility rules; ACDF never touches the AID lifecycle (retire is anchor-initiated only) |
| ERC-8419 KYA | Expresses and verifies trust conditions | Eligibility rules reference KYA assertions and policies; ACDF results may serve as evidence for a KYA scheme, but ACDF never edits anyone's credit |
| ERC-8414 Task Tenders | Task commitment and settlement | ACDF becomes one implementation behind `acceptanceAuthority` through an adapter; the 8414 kernel does not depend on ACDF |
| ERC-8338 Executable Skills | Skill assets | Source of subjects such as skill-quality disputes and skill admission |
| ERC-8004 | Identity / reputation / validation registries | Data source for identity and reputation; an optional bridge may mirror results lossily into the Validation Registry |

In one line: **AID identifies the subject, KYA expresses and verifies trust conditions, ACDF organizes authorized collective decisions, and applications such as Task Tenders execute their own committed consequences.**

### 1.5 Relation to prior work (the question every reviewer will ask)

| Prior work | What it does | Difference / relation |
|---|---|---|
| ERC-792 / ERC-1497 (Kleros) | Arbitrable / Arbitrator interfaces; evidence events | The arbitration profile provides a defined, tested adapter; 1497-style events are reused for evidence |
| ERC-8033 Agent Council Oracles | Info Agents commit-reveal answers, a single Judge aggregates, bonds are slashable, optional dispute | A concrete flow for information queries; expressible as an ACDF configuration (authorized-submitter acceptance plus a dispute round). ACDF differs in authorization, eligibility, body composition, general rules and result effect |
| ERC-8183 Agentic Commerce | Single `evaluator` address; `complete` / `reject` are terminal; explicitly excludes dispute resolution and multi-party voting | An ACDF adapter can be the evaluator; once the core settlement is done, no outer procedure overturns it |
| ERC-8226 Regulated Agent Mandate | Principal → agent authorization bounded by scope, time and amount | Same shape, opposite direction: 8226 authorizes an agent to act, ACDF authorization recognizes a rule set to decide; complementary (actions above a cap may require an ACDF result) |
| OpenZeppelin Governor / Timelock | Token-weighted voting plus timelocked execution | Established practice for separating decision from execution; Governor is one point in the ACDF parameter space |
| Safe multisig | Fixed-roster K-of-N | Equivalent to the minimal profile, plus issue binding, result records and NoDecision semantics |
| Kleros Court | Stake-weighted sortition, Schelling-point incentives, appeal with panel growth | Sortition and panel growth are borrowed as profiles; "agreeing with the majority is correct" is not adopted as a default incentive |
| Polkadot OpenGov | Origins / Tracks, Approval / Support curves, confirmation period, Fellowship | Borrowed: division of powers, sources of authority, amendability of institutions, dual-threshold curves. Not borrowed: network-security roles assembled into a pipeline |

The proposal does not claim an empty field: ERC-8033 already standardizes an Info / Judge flow for agent oracles. The difference lies in general authorization, eligibility, body composition, decision rules and result effect.

---

## 2. Design principles [Decided]

| # | Principle | In one sentence |
|---|---|---|
| P1 | Authorization precedes eligibility | Credit decides whether a subject deserves a kind of decision eligibility; authorization decides what it may decide. Voting forms a collective decision but creates no power and proves no truth |
| P2 | The registry is the normative record | Policy versions, issue bindings, procedure state, formal results and finality are read from the registry; relying contracts enforce committed effects within their own authority; only peripheral copies are "mirrors" |
| P3 | Policies are versioned | Old versions stay, new versions are published; new issues bind the new version, in-flight issues finish under the version they committed to; update rights must pre-exist |
| P4 | Eligibility, selection and weight are three things | Eligibility is not selection; high credit is not unbounded weight |
| P5 | Termination is determinate; NoDecision is legitimate | Every procedure has a determinable terminating path; "no decision formed" is a formal result, never dressed up as rejection or approval; consequences are committed in advance |
| P6 | Bodies compose by algebra | Several bodies' decisions combine through ALL / ANY / K-of-M / VETO, never by pooling ballots into one weighted sum |
| P7 | Machine verification is not voting | Recomputable verification goes through verifier paths (8414's verifier), not "0-of-0 voting"; optimistic confirmation is not θ = 0 — it needs challenge eligibility, a window and escalation rules |
| P8 | No global root | Each governance domain's root is its own source of authority; the standard defines no central registry and no "supreme court" over all agents |
| P9 | Decision and execution are decoupled | The kernel gains no control over external assets by forming a decision; procedure state, outcome type and enactment status are separate dimensions |
| P10 | "Agreeing with the majority" does not define correctness | Procedural performance may be paid, provable violations may be penalized, judgment quality is updated from later observable outcomes or independent review |

---

## 3. Object model

### 3.1 Overview

```
 Decision Policy (versioned, content-addressed, member of a policy family)
        |  an issue binds one policy version at filing
        v
 Issue -- bindings[] --> Consumer (relying contract) commits to accept the result and enforce it within its own authority
   |   subject / question / outcomeSpace / effectCandidates / disposition / snapshot
   v
 Body Instance(s) (created per round from the policy)
   |   ballots --> Body Decision in { Pending, Decided(o), NoDecision(r) }
   v   a single body is adopted directly; several bodies are composed by the algebra
 Result = procedure state x outcome type
   v
 Enactment: the consumer / executor reads the result, re-verifies, enforces; enactment status is recorded by the enforcing party
```

Six object kinds: Decision Policy, Issue, Authorization (present as the consumer's acceptance record and the issue's bindings, not as a stand-alone "mandate" object), Body and Body Decision, Result, Enactment Record. Evidence attaches to issues as events.

### 3.2 Decision Policy

A policy is a **template**: it answers "by which institution is this kind of matter decided". Policies are content-addressed (`policyId` = hash of the canonical encoding) and immutable once registered; change means publishing a new version, linked through a **policy family**. The family records its update authority: who may publish the next version.

| Component | Question answered | Minimal profile (MUST) | Open range (profiles) |
|---|---|---|---|
| eligibility | Who may enter the candidate pool | Fixed roster (ROSTER) | Credit-qualified agents (8419 / 8434), bonds, domain assertions, conflict exclusion |
| selection | Who participates this time | The whole roster | OPEN / NOMINATED / SORTITION / DELEGATED |
| weight | How opinions count | Equal | Credit-weighted, bond-weighted, lock-weighted; per-operator caps, diversity conditions |
| outcomeSpace | Shape of the answer | BINARY | CATEGORICAL / SCALAR / RANKED / SET |
| aggregation | When which decision forms | Absolute K-of-N | Participation / approval / support thresholds with confirmation period and time curves; weighted median; Condorcet, etc. |
| composition | How several bodies combine | Single body | ALL / ANY / K-of-M / VETO; finite, acyclic; may carry ordering dependencies |
| timing and clock | Phase lengths, which clock | One voting window; timestamp clock | Empanelment, evidence, commit, reveal, confirmation and challenge windows; block clock |
| appeal | Review, how many rounds, who may file | 0 rounds | Finite rounds, panel replacement / growth, bonds, total time cap |
| termination | When and why NoDecision arises | Deadline without threshold | Tie, insufficient participation, dependency failure, data unavailable |
| resultAcceptance [R3: body-level] | How a formal result enters the registry (declared per body; the policy only supplies defaults) | On-chain tally | Signed-ballot batch acceptance (same tally semantics as on-chain), authorized submitter (the registry verifies only submitter identity, result binding and timing; it does not re-tally) |
| dependencies [R3] | How referenced modules are pinned | None: the kernel is non-upgradeable and body kinds are built in at fixed versions | Mutable dependencies (dynamic KYA revocation, upgradeable verifiers) are a separate, explicit configuration declaring the dynamic range, check instant and consequence of failure; an address plus code hash does not by itself constitute freezing (an ERC-1967 implementation slot is mutable, and fixed code may read mutable storage) |
| update authority (family-level) | Who may publish a new version | A designated account | Multisig, committee, another ACDF decision |
| emergency | Can it pause, who, with what effect | None | Pre-declared pause conditions, authority and effect on in-flight issues |
| instantiable parameters [R3] | Which parameters are filled at filing, by whom | None (v0.2: the policy fixes every body and window; an issue carries only subject, question, effects and disposition) | Candidates, panel-size ranges, window ranges; the setter is determined jointly by the policy and the authorization relation, the relying party commits the final parameters, and the filer can never lower a threshold; Advisory issues also need a lawful parameter path |
| fees and bonds | Who pays, how it is distributed | None | Filing deposit, participation bond, appeal bond, procedural compensation |

[R3] The policy hash must bind the real execution parameters. In the v0.2 reference implementation `policyId = keccak256(abi.encode(PolicySpec))`; the `PolicySpec` contains every parameter that influences eligibility, weight, thresholds, composition, timing and finality, and is stored on-chain in full. There is no room for "the JSON says 3-of-5, the contract received K = 2". `descriptorHash` only references the human-readable descriptor; it belongs to the hashed object but never influences execution. The JSON mirror (`assets/erc-acdf/schemas/policy-spec.schema.json`) exists so other languages can reproduce the encoding; cross-language vectors are in `assets/erc-acdf/vectors/policy-id.json` (ethers v6 encoding checked against solc).

### 3.3 Issue

An issue is a **binding**: it fixes a concrete subject, a concrete question, a policy version and a set of acceptance relations together.

| Field | Meaning | Set by | Frozen at |
|---|---|---|---|
| issueId | Issue identifier (includes chainId and registry instance) | Registry | Filing |
| policyId | Bound policy version | Binding creator | Filing |
| params | Parameters the policy allows to be instantiated | Per the policy's instantiable declaration; setter restricted | Admission |
| subject | (chainId, contract, id, dataHash) | Filer | Filing |
| question | Hash of a schema-described question (e.g. "does submission S satisfy task T's acceptance criteria") | Filer, within the acceptance scope | Filing |
| outcomeSpace | This issue's instance of the outcome space | Binding creator | Admission |
| effectCandidates | The consumer action and magnitude each outcome maps to | Consumer | Admission |
| bindings[] | Verified acceptance relations: consumer, mode, scope reference | Consumer | Admission |
| effectClass | Binding (has acceptance) / Advisory (none) | Derived from bindings | Admission |
| disposition | Reference to the consumer's committed NoDecision disposition | Consumer (with the standing acceptance or at filing) | Admission |
| filer | Filer and its standing | Policy initiation rule plus acceptance scope | Filing |
| deadlines | Consumer hard deadline; absolute instants of this issue's windows | Policy plus consumer | Admission |
| snapshot | Commitment to eligibility and weight | Admission process | Admission |
| evidenceRoot | Evidence references (1497-style events) | Any party | Until the deadline the policy declares |

Filing (Filed) and admission are distinct: filing records intent; admission completes verification and freezing and opens the first round. CONSUMER_FILED and STANDING_ACCEPTANCE admit atomically in one transaction; POST_ACK stays Filed until the relying contract acknowledges. The reference implementation has no separate Admitted state: admission is the Filed → Deciding transition.

### 3.4 Authorization

Authorization answers "who recognizes this rule set as having decision power over which matters and effects". It is not a stand-alone object but structured data in two places: the relying contract's acceptance record (its own permission system, or a standing acceptance registered in the registry), and the issue's bindings. See section 5.

### 3.5 Body and Body Decision

A body is an instance, for one issue and one round, of a combination of eligibility + selection + weight + aggregation drawn from the policy. The minimal profile has exactly one body; the composition profile has a finite acyclic body graph.

A body decision takes three kinds of value: Pending, Decided(outcome) (for binary bodies: approve or block) and NoDecision(reason) — the four values the review required: not finished, approve, block, terminated without decision.

Reason codes (v0.2 reference implementation): QUORUM_NOT_MET (roster body closed without reaching either threshold), SUBMITTER_SILENT (authorized submitter did not report within its window), NO_CLEARANCE (under REQUIRE_CLEARANCE the veto body neither vetoed nor cleared), NOT_REACHED (a composite node cannot be determined from its children, including "the required joint approval did not form"), TOTAL_TIMEOUT (the hard cap arrived with the round still Pending), NO_ACCEPTANCE (a POST_ACK window lapsed without acknowledgment and the issue closed). VETOED is the reason of a Decided(no), not of a NoDecision. Reserved for non-binary and future profiles: TIE, DEPENDENCY_FAILED, DATA_UNAVAILABLE, EFFECT_MISMATCH.

### 3.6 Result

A formal result is the combination of two independent dimensions:

- **Procedure state**: Filed → Deciding → Provisional → Final; and Withdrawn.
- **Outcome type**: None (not yet) / Decided(outcome) / NoDecision(reason).

Legal combinations: Filed × None, Deciding × None, Provisional × Decided, Provisional × NoDecision (when that outcome type is appealable), Final × Decided, Final × NoDecision. "Final, with NoDecision as the outcome" is a normal state.

A formal result carries: policyId, round count, each body's decision, tally commitments (counts or weights and a commitment to the ballot set), the instant it was determined, and the instant it became final.

### 3.7 Enactment Record

Enactment status is recorded per (consumer, effectId): NotEnacted / Enacted(ref) / Failed(reason). Execution state is authoritative at the relying contract (it is that contract's state); the registry offers an informative log entry, never overriding the relying contract's state and never modifying a decision because some relying party failed to execute. De-duplication of fund movements is the relying contract's responsibility.

### 3.8 Evidence

ERC-1497-style events. Evidence is submitted as content-addressed envelopes with a schema and a size limit. Participants must treat evidence as data, not as instructions (section 10).

---

## 4. State machine

### 4.1 Procedure-state transitions

| Transition | Trigger | Condition |
|---|---|---|
| — → Filed | Filer calls `file` | Filer satisfies the policy's initiation rule; subject and question are well-formed |
| Filed → Deciding (admission) | Admission: atomic with filing for CONSUMER_FILED and STANDING_ACCEPTANCE; after the consumer's acknowledgment for POST_ACK | Bindings verified (5.2); remaining-window check passes (`admittedAt + maxTotalDuration ≤ consumerDeadline`, 9.4); no other unfinished Binding issue for the same obligation; snapshot taken; round 1 opens immediately |
| Filed → Deciding (Advisory admission) | POST_ACK window lapsed without acknowledgment, and the policy allows Advisory | Consumer and effects cleared; can never be upgraded to Binding afterwards |
| Filed → Withdrawn | Filer withdraws; or POST_ACK window lapsed without acknowledgment and the policy forbids Advisory | [R3] Unilateral withdrawal only while Filed |
| Deciding → Provisional | The round's composite result forms (Decided or NoDecision) | A legal appeal opportunity remains (rounds left and that outcome type appealable), and result instant + appeal window has not passed |
| Deciding → Final | The round's composite result forms | [R3] No remaining legal appeal or challenge opportunity: appeals never allowed, rounds exhausted, that outcome type not appealable, or the appeal window — counted from the result instant — has already lapsed (a late settlement cannot stretch the procedure) |
| Provisional → Deciding | Appeal accepted | Someone with standing files within the window; the new round rebuilds every body instance under the original policy version |
| Provisional → Final | `finalize` (permissionless) | Appeal window lapsed without appeal |
| Deciding / Provisional → Final | `enforceHardDeadline` (permissionless) | Past `admittedAt + maxTotalDuration`; a round still Pending is recorded as NoDecision(TOTAL_TIMEOUT) |

[R3] Withdrawn is reachable only from Filed and only by the filer. Once admitted, the roster, snapshot and windows exist; even before the first ballot the filer must not be allowed to withdraw and refile, or it could shop for panels. Joint cancellation after admission can only be a pre-declared extension. A relying contract cannot unilaterally tear up an in-flight binding (P3). The reference implementation realizes admission as the atomic Filed → Deciding transition without a separate Admitted state.

### 4.2 Determining the outcome type

The outcome type is composed from the current round's body decisions under the composition rule (a single body is adopted directly). A Decided outcome must lie inside the outcome space frozen at admission; a NoDecision must carry a reason.

[R3] A Provisional result may be superseded by the result of a lawful appeal round; **Final is never replaced by a later round of the same issue**. Correcting or changing business state later requires a new, authorized issue; the old decision stays as a historical fact and never becomes "never final".

[R3 new decision] When an appeal round forms no decision, the most recent substantive decision is kept by default: round 1 explicitly rejects, the losing side appeals, round 2 ends in NoDecision for lack of participation — the final result adopts round 1's rejection; round 2's NoDecision is recorded separately and does not erase it. Only when no round produced a substantive decision does the issue end as NoDecision. The Result therefore records both `roundCount` (the last round attempted) and `sourceRound` (the round whose decision was adopted); they may differ. A configuration in which "re-hearing cancels the earlier result" can be declared explicitly, never as an implicit default.

[R3] Which bodies an appeal covers must be stated: in v0.2 an appeal rebuilds **all** body instances (including a screening body) and re-runs them under the original policy version; "carrying a body's decision over from the previous round" is a future explicit configuration.

Timing freezes the computation rules rather than every future instant: at admission the start instant, total hard deadline, phase durations, start conditions and computation method are frozen; the actual start instants of later rounds are recorded under those rules. The appeal window counts from the **instant the result was determined**, not from the settlement call, so failing to call `settleRound` cannot stretch the procedure. The hard-cap path covers both non-final states, Deciding and Provisional. "Anyone may call `finalize` / `enforceHardDeadline`" provides a callable path; the chain does not execute it on anyone's behalf.

### 4.3 Enactment status

Enactment status is independent of the other two dimensions: the same Final × Decided result may be read by several relying parties, each succeeding or failing on its own. A relying party re-verifies before executing (9.4).

### 4.4 Procedural finality versus chain finality

Procedural finality (Final) is a procedural fact recorded by the registry; it does not substitute for the chain state carrying that record having reached the required confirmation depth. Relying parties — cross-chain readers above all — declare their own chain-finality assumptions.

---

## 5. Authorization layer

### 5.1 What authorization is and is not [Decided]

Authorization is a relying contract's commitment: "I accept the final results of policy P in registry R for issue class C and subject set S, and I enforce effect E within my own authority (with caps and validity)."

- Someone writing "I have power over contract X" into the registry gains no power; power comes only from the relying contract's own act of acceptance.
- A relying contract cannot re-count ballots or swap thresholds because it dislikes a result: pass or fail is read from the registry record; which funds may move, whether execution already happened and whether execution conditions still hold are checked by the relying contract (P2).
- "There are only four sources of power: property, contract, association, derivation" stays a motivational statement in this memo and in the Rationale; it is not written as a normative axiom.

### 5.2 Three acceptance modes [Proposed, adopted]

| Mode | Mechanism | Typical use | What the registry verifies at admission |
|---|---|---|---|
| CONSUMER_FILED | The relying contract (or its adapter) calls `file`; `msg.sender` is the consumer; acceptance is implied and admission is atomic | 8414 adapter, 8183 evaluator, 792 Arbitrable `createDispute` | Filer == the bound consumer. [R3] This only proves that this consumer initiated the filing; an adapter must itself verify that it holds the business authority it claims (the 8414 adapter checks `acceptanceAuthorityOf(tokenId) == adapter`); a caller "claiming to be the adapter" never yields a valid binding over an arbitrary task |
| STANDING_ACCEPTANCE | The relying contract pre-registers: accepted policy version (referenced, never copied), subject constraint, question constraint, who may file, committed effects and disposition, validity; listed filers file within it | Charters: any member may propose a parameter change or an admission | Every field of the issue falls inside the acceptance; the acceptance was registered by the consumer itself and has not expired or been revoked |
| POST_ACK (file, acknowledge, admit) [R3 revised] | Anyone files and names the consumer; the issue stays **Filed** and cannot be voted on; the consumer acknowledges within the policy's `ackWindow`, supplying the final effects and disposition, and only then is the issue admitted as Binding. If the window lapses: Advisory admission when the policy allows it, otherwise closure (Withdrawn, reason NO_ACCEPTANCE) | One party initiates, the other later agrees to be bound | Acknowledgment comes from the named consumer, within the window, while the issue is still Filed; outcome space and effect candidates freeze at acknowledgment. An issue admitted as Advisory can **never** be upgraded in place to Binding after ballots or results are visible; a party that later wants to adopt its result must create a new acceptance record or a new issue |

A standing acceptance is the relying contract's declaration about itself; it references a definite policy version and never maintains a second copy of the rules (P2). It is not a "mandate registry": it grants nobody any power; it only declares what the relying contract will accept.

### 5.3 Binding versus Advisory [Proposed, adopted]

An issue with non-empty bindings is Binding; with none it is Advisory. Advisory issues run the full procedure and produce a formal record but no hard effect; an 8419 scheme may interpret them as evidence within its own scope. This gives "influence through credit rather than through courts" a formal path and gives "one domain's decision does not bind another" an object-level expression. A policy may demand a deposit for Advisory issues or forbid them (`allowAdvisory` in v0.2).

[R3] Binding is limited to a specific relying party and specific effects. "Bindings are non-empty" may serve as a display label, but an executor must not read it as "this decision binds every party involved": in v0.2 an issue binds a single consumer; when an effect needs two resource controllers to accept jointly, the required acceptance set and its completion condition are a future extension, checked at admission.

[R3] One decision obligation under one business authorization has at most one live Binding issue. v0.2 identifies the obligation by `obligationKey = keccak256(consumer, subject, question)`: while the previous issue is not terminal (neither Final nor Withdrawn) no new issue may be filed for it; review happens through the committed appeal path or through the relying party's own refiling rules. Different governance domains may still decide separately about the same fact (different consumers are different obligations); what is forbidden is shopping for a favourable verdict on the same execution obligation.

### 5.4 Freezing at admission and non-expansion [Decided]

Frozen at admission: policy version, params, outcome space, effect candidates, bindings, disposition, eligibility and weight snapshot, and the way denominators are determined. Statistical bases cannot be swapped after ballots are visible. Conditions that must be checked live (e.g. whether revocation of an eligibility assertion invalidates a ballot, and up to which instant) are declared in advance as **dynamic dependencies**.

Non-expansion: a result can only fall inside the frozen outcome space, an effect can only be one of the frozen effect candidates, and magnitude never exceeds the acceptance cap. No decision can enlarge the authorization it rests on.

### 5.5 Versions, update authority, emergency clauses [Decided]

- Publishing a new version requires the family's update authority, fixed when the family is created; it can be an account, a multisig, a committee or another already-authorized ACDF decision. The decision at hand cannot declare itself to hold the update authority.
- Publishing a new version does not make existing relying parties adopt it: standing acceptances and filing bindings point at a specific version. A relying party may choose to accept "any version of family F published by authority U"; that is the relying party's own choice and affects new issues only.
- [R3] Freezing must move from a textual promise to a commitment over execution parameters: every parameter that influences eligibility, weight, thresholds, composition, timing and finality enters a verifiable canonical encoding commitment (v0.2: the whole `PolicySpec` is stored on-chain and hashed into `policyId`; cross-language vectors cover field order, integer precision and array order). Addresses, code hashes and admin allow-lists cannot prove freezing on their own: an ERC-1967 proxy changes its implementation address in a storage slot while the proxy code stays the same, and fixed code may read mutable thresholds or lists. The first version therefore uses a **non-upgradeable kernel + built-in fixed-version body kinds + execution configuration bound to the policy**; dynamic KYA revocation, upgradeable verifiers and similar needs become separate configurations that declare the dynamic range, check instant and failure consequence, and are no longer called fully frozen.
- Ordinary changes protect in-flight issues. Where an emergency pause is truly needed, the policy must pre-declare trigger conditions, authority and consequences (e.g. pausing new filings only, leaving in-flight issues alone); "every revocation waits out a notice period" is not imposed as a blanket rule. v0.2: a standing acceptance may be revoked by its consumer; revocation blocks new filings only, and in-flight issues complete as committed.
- Clock consistency: one registry instance uses one clock (v0.2: timestamp, disclosed through ERC-6372 `clock()` / `CLOCK_MODE()`); block counts are never converted to "guaranteed" seconds.

### 5.6 Not in the v1 kernel [Decided]

Full authorization trees, recursive re-delegation and shared-budget management (a parent cap of 100 split into two child grants of 100 each) are additional mechanisms left to later profiles. v1 standardizes update boundaries and version protection only.

---

## 6. Eligibility, selection, weight

### 6.1 Framework requirement versus the credit-qualified profile [Decided]

The framework requires eligibility rules to be **verifiable** and snapshotted at admission. A fixed-roster 3-of-5 meets the minimal framework, but the existence of a roster alone never lets it claim "credit-qualified agent deliberation".

The Credit-Qualified Agent profile (Finch's default) binds strictly to ERC-8419 and ERC-8434 and specifies **complete verification semantics**; it never assumes a single existing function does everything:

- Identity anchor: the 8434 AID is Active and bound one-to-one to an 8004 agentId; Stale or Retired disqualifies. The AID's binding and liveness are **not** sybil resistance: a heartbeat proves key control, not behavioural quality.
- Trust conditions: the 8419 scheme and level named by the policy, verified including issuer acceptance, admission domain, validity window, binding to the identity anchor and declared external conditions. KYA's on-chain `evaluate` is an optional extension; the profile must state who closes the gap between a local on-chain check and full policy satisfaction.
- Domain binding: eligibility must relate to the matter's domain. A record of financial performance does not confer competence in contract security or fact checking; levels from different schemes must not be blended into an unexplained "universal credit score".
- Conflict exclusion: parties and their affiliates (per 8434 bindings and declared affiliations) are excluded from the candidate pool for that matter.
- Optional bond.

### 6.2 The three-way split and selection modes [Decided]

Eligibility decides who may enter the pool; selection decides who participates this time; weight decides how an opinion counts. Each is configured and snapshotted separately.

Selection modes: OPEN (every eligible participant may vote), ROSTER (fixed list), NOMINATED (parties or nominators propose, with optional mutual strike rules), SORTITION (verifiable random draw from the pool, optionally weighted by credit or bond, with a panel size set by the policy or by objective attributes of the matter), DELEGATED (per-domain delegation).

Nomination and guarantee are distinct: nomination is "recommending someone to stand"; a guarantee is "bearing losses for them", and it must have a matter scope, validity, liability cap and trigger conditions — it never becomes "an established agent's credit can be lent without limit to a new one". Nomination helps cold starts; it must not become a printing press for governance power.

### 6.3 Weight and independence handling [Decided direction]

How weight and independence are handled must be explicit and verifiable in the policy; the specific algorithm stays open. At least three questions are kept apart:

| Problem | What must be identified | Configurable handling |
|---|---|---|
| Concentrated control | Whether several agents are controlled by the same principal | Per-operator weight caps, per-operator selection caps |
| Correlated judgment error | Shared model, information source, memory or bias | Model / source diversity conditions |
| Aligned or conflicting interest | Benefiting from the same outcome, or affiliation with a party | Conflict exclusion, recusal |

Whether these conditions hold must state the evidence source and the residual trust assumption. A self-declared "different operator" is not proof of independence. "N agents running the same model equal one vote" is not used as normative language.

### 6.4 How the eligibility snapshot is produced [Open]

When the pool is large and eligibility depends on off-chain or expensive verification: per-member on-chain verification, a submitted commitment with a challenge period, or a ZK proof. Deferred to the eligibility round.

---

## 7. Voting and aggregation

### 7.1 Outcome-space types

BINARY (two options), CATEGORICAL(m) (one of m), SCALAR(range, unit, precision) (a number, typically "what fraction to pay"), RANKED (an ordering), SET (any subset). A relying contract accepts only the types it can enforce (11.1).

### 7.2 Complete semantics of the minimal K-of-N [Proposed, adopted]

Fixed roster N, equal weight, one voting window.

- Valid approvals ≥ K: Decided(yes), formed immediately.
- Valid blocks ≥ N − K + 1 (approval has become impossible): Decided(no). This is the body's explicit rejection, not a failure to decide.
- Window closes with neither condition met: NoDecision(QUORUM_NOT_MET).
- One ballot per member; late ballots are invalid; the minimal profile forbids changing a ballot (the first one counts); ballot changes and commit-reveal belong to profiles.
- Abstention equals not voting in the minimal profile; general profiles may have an explicit ABSTAIN for participation thresholds.

[R3] This is an **approval rule for a designated proposal**, not a symmetric tribunal where each side needs K votes: "no" means this proposal has been blocked by this rule; it does not automatically establish the opposite substantive proposition. Under 4-of-5, two blocks stop approval — that does not mean four members found the other side right, only that the proposal can no longer reach four approvals. In binary acceptance it may be pre-authorized to map to rejection; the interpretation must not be extended unconditionally to guilt / innocence, two competing plans or truth / falsity; a tribunal where each side must reach a threshold uses an explicit two-threshold configuration whose middle region yields NoDecision. The two thresholds can never hold simultaneously: that would need K + (N − K + 1) = N + 1 valid ballots out of N. The reference implementation fixes N ≥ 1, 1 ≤ K ≤ N, unique members and an invariant denominator, and de-duplicates by (issue, round, body, voter) — a fresh signature nonce buys no second vote.

### 7.3 General binary pass conditions [Decided]

An optional binary configuration may enable three conditions separately, with W_E the total available voting weight fixed at the snapshot under the round's rules:

- Participation threshold: (W_yes + W_no + W_abstain) / W_E ≥ q
- Approval ratio: W_yes / (W_yes + W_no) ≥ a; a zero denominator counts as not satisfied
- Support ratio: W_yes / W_E ≥ s

Enabled conditions must hold continuously through a **confirmation period**; a may be a declared curve decreasing with elapsed time (in the spirit of OpenGov's Approval / Support, not a literal copy). All comparisons use integer cross-multiplication, never division with rounding. Example: 10 of 100 weight units participate, 8 approve — an 80% approval ratio and an 8% support ratio; whether it passes depends on which conditions are enabled.

### 7.4 Non-binary aggregation

CATEGORICAL: weighted plurality or a declared Condorcet / IRV; SCALAR: weighted median (robust to outliers), with ties resolved to the lower or upper bound as declared and results clamped to the range; RANKED: Schulze / IRV; SET: per-item thresholds. Tie rules must be declared, otherwise NoDecision(TIE).

### 7.5 Result-acceptance modes [Proposed, adopted]

| Mode | Mechanism | Verification responsibility |
|---|---|---|
| ON_CHAIN_TALLY | Each ballot is a transaction; the registry tallies accepted ballots deterministically; `finalize` is permissionless | Registry |
| SIGNED_BALLOTS (batch acceptance) [R3: the first version's "verified aggregate"] | Agents sign EIP-712 ballots off-chain (bound to chainId, registry address, issueId, round, body, voter and position; **no nonce** — the voter's identity is the only key); anyone submits batches; the registry verifies each signature (ECDSA for EOAs, ERC-1271 for contract accounts) and counts under **the same tally semantics**; acceptance time is the submission block | The registry verifies signatures and their binding to the same roster, issue, round and body; a second, contradictory signature by the same voter in the same round is refused and constitutes a provable violation |
| AUTHORIZED_SUBMITTER | The policy pins one contract or account as submitter (an external DAO vote contract, an 8033-style Judge); the registry verifies submitter identity, timing and that the result lies in the outcome space | The registry **does not re-tally** the submitter's internal vote; it only recognizes the pre-designated body's result; the submitter's own rules are referenced and pinned by the policy |

[R3] The three modes are body-level fields (`BodySpec.acceptance`); different bodies of one policy may differ (Case B: the technical chamber uses signed ballots, the economic chamber on-chain tallies). Verification promises must not be blurred: a genuine signature does not mean no ballot is missing, and "this batch's approval ratio" is not "the round's ratio" — after six rejections are recorded, a batch of four approvals must not be read as 100% approval; in the reference implementation later batches simply add to the same body instance, and a body that has already Decided refuses further ballots. The first version implements no abstract universal proof aggregator; any extension claiming to prove "the aggregate of all valid ballots" must state its ballot-set commitment, data availability and completeness basis. EIP-712 provides no replay protection by itself and ERC-1271 validity may depend on contract state, so de-duplication, acceptance instant, contract-account verification and the rule that accepted ballots are never invalidated afterwards are all fixed by this configuration. Off-chain signing does not give up the registry's authority: a signature is a way to submit and carry evidence; it does not bypass acceptance rules and is not a state proof another chain can trust.

### 7.6 Clock and deadlines

The policy declares its clock mode (timestamp or block number, following ERC-6372 `clock` / `CLOCK_MODE`; timestamp by default). All windows are converted to absolute instants at admission. Deadlines follow **arrival semantics**: a ballot or result is valid only if the registry receives it before the deadline.

### 7.7 Boundaries of the privacy extension [Decided]

ZK-KYA can prove "eligibility satisfied without disclosing the raw data"; anonymous voting additionally needs anti-double-vote identifiers, identity-linking policy and verification mechanics. Eligibility privacy, ballot privacy and coercion resistance are different guarantees: even an anonymous voter who can prove to a vote buyer how they voted leaves the bribery problem intact (MACI treats privacy and coercion resistance separately). Private voting is supported as an extension; "uses ZK" is never packaged as "inherently fair".

---

## 8. Body composition (normative-optional profile) [Decided: in v1]

"Normative-optional": an implementation may not support the profile; one that claims support must follow the explicit rules and test vectors. The minimal form keeps a single body.

### 8.1 What is composed [Decided]

What composes is **bodies' decisions on the same issue and compatible candidate effects**, not context-free booleans. "Technical chamber approves paying 10, economic chamber approves paying 100" cannot combine into a pass because both are Yes. Every body result is bound to the same issueId and the same effect candidate; a composition rule cannot manufacture an effect that neither side approved after receiving two approvals.

### 8.2 Four-valued semantics and combinators [Proposed, adopted]

Node values are in { Pending, Decided(yes), Decided(no), NoDecision(r) } (a non-binary body's Decided carries its outcome).

| Combinator | Decided(yes) | Decided(no) | NoDecision | Pending |
|---|---|---|---|---|
| ALL(children) | All children yes on the same candidate effect | Any child no | No child no, at least one NoDecision, none Pending (reason: "the required joint approval did not form", naming the body) | Otherwise |
| ANY(children) | Any child yes (may finish early; the other bodies need not wait) | All children no | No yes, not all no, none Pending | Otherwise |
| K-of-M(children) | ≥ K children yes on the same candidate effect | > M − K children no (yes has become impossible) | None Pending and neither of the above | Otherwise |
| VETO(target, vetoer, window, silence) [R3 revised] | PASS_THROUGH: `now ≥ vetoClose ∧ no valid veto inside the window ∧ target is yes`; or the vetoer **explicitly cleared** inside the window (Decided(no veto), irrevocable) and target is yes. REQUIRE_CLEARANCE: the vetoer explicitly cleared and target is yes | The vetoer Decided(veto) inside the window, reason VETOED; or (after the window closed or clearance) target is no | REQUIRE_CLEARANCE: window closed without clearance (NO_CLEARANCE); or (after the window closed or clearance) target is NoDecision | Window open and the vetoer undecided — **whatever the target says**; or target still Pending |

ALL and ANY are special cases of K-of-M (M-of-M and 1-of-M). VETO is expressed separately because it carries a holder, a window and a silence semantics: "the screening body explicitly vetoed" and "the screening body never responded" are not the same thing. Both silence regimes are supported, but one must be chosen explicitly; code treating an empty value as zero must never pick one by accident.

[R3] A still-live veto right, challenge right or mandatory input window is never extinguished by an early `finalize`. With a 12-hour veto window and both chambers approving in hour 1, the remaining 11 hours of veto right cannot be hollowed out: the VETO node stays Pending until the window closes or the vetoer decides, so settlement necessarily fails. The priority between "target = NoDecision" and "a veto may still occur" follows: a valid veto inside the window always prevails, and the result type is a pure function of (ballots, time), independent of the order of `finalize` calls (see `test/ACDFComposition.t.sol::test_VETO_result_type_does_not_depend_on_settlement_order`).

Each composite node also has a determinate **formation instant**: Yes forms when the k-th approval arrives, No when the (M−K+1)-th block arrives, NoDecision when the last child settles; a VETO node forms at the later of the window close (or the vetoer's decision) and the target's formation. The appeal window counts from this instant.

### 8.3 Dependencies and ordering

The body graph is finite and acyclic; a node may declare `after` dependencies whose windows open once the dependencies complete; the total duration is bounded by the sum of windows along the longest path plus appeals. An upstream NoDecision marks dependent downstream nodes NoDecision(NOT_REACHED) and keeps the reason. Screening → review ordering is allowed; what is rejected is forcing every matter through a fixed pipeline. (v0.2 runs all bodies of a round in parallel and expresses screening through the VETO window; explicit `after` dependencies are Planned.)

### 8.4 Composition over scalar results [R3 decided]

The right abstraction is "the intersection of allowed effect sets", not "smaller is always safe". "Must pay 10" and "must pay 100" are two different exact results and cannot simply become 10; "may pay at most 10" and "may pay at most 100", with consistent units, lower bounds and other constraints, yield the jointly allowed range E_allowed = E_1 ∩ E_2, from which a pre-declared selection rule produces the result. Formally this is a set intersection, not an unconditional min(x_1, x_2): "smaller" favours the payer and is not necessarily reasonable for the payee; it has no universal safety meaning. The first CompositionProfile implements binary composition over the same candidate effect only (as in reference v0.2); scalar composition is reserved as a typed extension — exact amounts and amount caps are different types.

---

## 9. Finality, NoDecision and enactment

### 9.1 Three separate dimensions [Decided]

Procedure state, outcome type and enactment status are independent (section 4). "Final with NoDecision" and "the same decision executed successfully by one party and unsuccessfully by another" are both normal.

### 9.2 Appeals and finality [Decided]

Every configuration fixes the maximum number of appeal rounds (zero is lawful), the total time cap, the replacement rule (e.g. a fresh draw with growth to 2k + 1), appeal standing and bond, and what happens if no decision forms in the end. A final tier with human participation is an optional configuration, never the framework's default supreme power; a pure A2A system must be able to complete normal decisions without human intervention. A "constitutional track" is a governance domain's own root rule, not a world court over all agents.

### 9.3 Disposition of NoDecision [Decided]

Two semantics are kept apart:

- ACDF's procedural semantics: why no decision formed, when the procedure ended, whether a lawful follow-up procedure exists. Recorded by the registry.
- The application's disposition semantics: keep the status quo, re-empanel, refund, hand over, wait for existing settlement conditions. Enforced by the relying contract according to a **prior commitment**; the disposition reference is frozen with the issue at admission.

The filer may never choose between "undecided → refund" and "undecided → pay". Where filing-time routing is really needed, it follows pre-authorized objective conditions or a body with explicit discretion. What is forbidden is unauthorized favourable choice, not all discretion.

### 9.4 Enactment [Decided]

- Reversibility matching: irreversible effects (asset transfers) only on Final; Provisional only for reversible or compensable effects.
- Arrival semantics: deadline-bound actions (rejection above all) must actually be received by the target contract before the deadline; a receipt claiming to have formed in time does not cure a late call.
- Remaining window: at admission check **maximum procedure duration + submission margin ≤ consumer hard deadline − now**, not the original window length; a case filed long after submission may have too little time left. With several relevant deadlines the earliest one counts (8414: the judgment window bounds rejection, `settleBy` bounds acceptance). Reference implementation: the relying contract passes the deadline net of its margin as `consumerDeadline`; the registry verifies `admittedAt + maxTotalDuration ≤ consumerDeadline`.
- [R3] Execution failure never modifies Final and never marks an effect as permanently enacted unconditionally; whether a retry is possible depends on the target's state and the committed execution rules (reference implementation: a Failed record may later be overwritten by Enacted; Enacted is never overwritten by Failed). The execution entry point may be permissionless, but the caller can only request the effect already bound — never another target address or arbitrary calldata.
- [R3] The informative enactment log accepts reports only from the bound consumer (or its authorized executor), keyed by issue, result, relying party and effect, recording the real reporter; third parties cannot fake "executed", and a failure report never overwrites a genuine success record.
- Type matching: ACDF may output a scalar such as "pay 40%", but an adapter into an application that only accepts binary results must map supported results explicitly and refuse unsupported types at admission rather than converting silently.

---

## 10. Incentives and security (principles) [Decided direction]

Incentives are separated by basis: procedural performance (submitting a valid judgment on time, carrying out committed review) may be compensated; provable violations (contradictory signed ballots within one round, breaches of committed procedural duties) may be penalized; judgment quality is updated from later observable outcomes, reviewable evidence or independent assessment, never by majority coherence alone; for policy choices without an objective answer, "differing from the winning policy" is not a credit defect. Money incentives, credit feedback and their combination are all compatible; the kernel mandates no particular slashing or scoring algorithm.

How results enter credit systems: ACDF outputs results carrying the policy version, scope, finality state and evidence references, to be interpreted and adopted by an authorized KYA scheme or another credit system. This is traceable evidence feedback, not "the ruling contract rewrites everyone's aggregate credit score". Legitimate sanctions are suspending membership in a governance domain, removing a class of voting eligibility, or issuing a negative assertion valid under a specific scheme; none of them destroys the subject's identity.

Security considerations (the seed of the ERC section):

| Risk | Handling |
|---|---|
| Sybil | Credit thresholds and per-operator caps, with residual trust assumptions disclosed |
| Bribery and coercion | Commit-reveal, privacy profile; coercion resistance has its own trust model and is never promised in the name of ZK |
| Correlated judgment | Declared independence handling (6.3) |
| Evidence injection | Evidence is data, not instructions; policies may require rationale commitments |
| Appeal griefing | Bonds, caps on rounds and total time |
| Liveness | Deadlines, permissionless `finalize`, NoDecision as a determinate end |
| Upgradeable dependencies | Non-upgradeable kernel, built-in fixed-version bodies; mutable dependencies declared separately |
| Time manipulation | Declared clock mode, submission margins, arrival semantics |
| Replay | Signatures bound to chainId, registry, issueId, round, body and voter; identity-keyed de-duplication |
| Registry-instance trust | Relying parties bind to a specific instance; the instance's governance and upgrade path must be disclosed |

---

## 11. Interfaces to existing standards

### 11.1 ERC-8414 adapter [Decided boundary]

- The adapter (`ACDFTaskTenderAdapter`) is the task's `acceptanceAuthority`; the 8414 kernel does not depend on ACDF. Before opening a case the adapter checks `acceptanceAuthorityOf(tokenId) == adapter`, and through ERC-165 it deliberately does **not** declare `ITaskVerifier`, so submissions follow the judged path rather than machine settlement.
- [R3] Real ABI: `submissionOf`, `tenderTermsOf`, `acceptFulfillment`, `rejectFulfillment` (TASK-KERNEL v3.0). When judgment is needed anyone may trigger `open(tokenId, submissionId)`; the adapter files a CONSUMER_FILED issue with subject = (chainId, TaskToken, tokenId, dataHash = keccak(submissionId, resultHash, the taskVersion cited at submission)); question = does the delivery satisfy the acceptance criteria; outcome space = BINARY{accept, reject}; effect candidates = {accept → acceptFulfillment, reject → rejectFulfillment}; disposition = defer to the task's own clock (`claimUnjudged`). Result hash and task version are bound, so work delivered against v1 is never judged against a later task description.
- [R3] Both clocks are reserved: `T_decision,max + T_margin ≤ min(submittedAt + judgmentWindow, settleBy) − now` (settleBy = 0 means no such deadline). The judgment window bounds `rejectFulfillment`, `settleBy` bounds `acceptFulfillment`; checking the judgment window alone could leave an ordinary acceptance past `settleBy`. This is the first adapter's conservative acceptance rule; it does not modify 8414's own semantics.
- One live issue per submission; a Decided issue is never re-litigated by refiling; reopening is allowed only after Final × NoDecision with enough time remaining.
- After Final × Decided(accept or reject) anyone may trigger `execute(issueId)`; the adapter can only call the bound (task, tokenId, submissionId) with the effect implied by the recorded outcome, and re-checks the submission's resultHash and taskVersion first. A kernel refusal (past `settleBy`, past the judgment window, epoch exhausted, authority changed) is recorded as Failed with the decision unchanged, and may be retried when the target's state allows. Final × NoDecision calls nothing on the task; 8414's `claimUnjudged` applies under its own rules — an early NoDecision in ACDF never means paying early, refunding immediately or restarting the task's clock.
- Scalar (partial payment) outcomes are configurable only when the task kernel supports partial settlement; otherwise the adapter accepts BINARY policies only.
- [R3] Fees: the upstream specification lists an in-kernel `judgmentFee` as a future candidate, not as a field or payment path of the current revision; the first version uses an independent juror-compensation arrangement and does not assume the task vault pays ACDF a judgment fee.

### 11.2 ERC-8183

The evaluator may be an ACDF adapter: it files on `submit` and calls `complete` / `reject` after Final; `expiredAt` must exceed the maximum procedure duration plus margin. Once the core settlement is done, no outer appeal overturns it.

### 11.3 ERC-792 / ERC-1497 arbitration profile

A wrapper implements `IArbitrator`: `createDispute(choices, extraData)` files a CONSUMER_FILED issue (`msg.sender` is the Arbitrable) with outcome space CATEGORICAL(choices); after Final it calls back `rule(disputeId, ruling)`; `appeal` maps to the ACDF appeal; `arbitrationCost` comes from the policy's fee clause; evidence reuses 1497 events. The adapter is defined and tested; the framework does not claim compatibility by breadth alone.

### 11.4 ERC-8004 / 8419 / 8434

8004: identity and reputation data source; an optional bridge may mirror Final results lossily into the Validation Registry (the mirror may lag and lose information; authority stays with the ACDF registry). 8419: eligibility rules reference schemes and policies; results are interpreted as evidence by schemes. 8434: identity anchor; ACDF never changes AID state.

### 11.5 ERC-8033 / 8226

8033's Info / Judge flow is expressible as "authorized-submitter acceptance plus a dispute round". 8226 and ACDF are complementary: an agent's transaction authorization may require an ACDF result for actions above a cap.

---

## 12. Two worked cases

Acceptance criterion: both cases must be written with the same objects (policy version, issue binding, body instances, body decisions, Result as procedure state × outcome type, enactment records) and the same state machine of section 4.

### 12.1 Case A: a fixed-roster 3-of-5 accepting one ERC-8414 delivery

| Object | Instance |
|---|---|
| Policy P_A v1 | eligibility = ROSTER(5 addresses); selection = all; weight = equal; outcomeSpace = BINARY; aggregation = K-of-N(K = 3; three blocks = Decided(no)); composition = single body; timing = 24h voting window, timestamp clock; appeal = 0; termination = deadline without threshold → NoDecision; resultAcceptance = ON_CHAIN_TALLY; dependencies = none; update authority = the task creator; emergency = none; instantiable = none |
| Issue I_A | policyId = P_A v1; subject = (TaskToken, tokenId, submissionId, resultHash, taskVersion); question = does the delivery satisfy the acceptance criteria; outcomeSpace = BINARY{accept, reject}; effectCandidates = {accept → acceptFulfillment, reject → rejectFulfillment}; bindings = [Adapter8414, CONSUMER_FILED]; effectClass = Binding; disposition = defer to the task clock; filer = Adapter8414; deadlines: consumerDeadline = min(submittedAt + judgmentWindow, settleBy) − margin, admission checks admittedAt + maxTotalDuration ≤ consumerDeadline; snapshot = the five-member roster, equal weight |
| Body B1 | The roster body, one round |
| Main path | Filed → Deciding (atomic admission); three accept ballots on-chain → B1 Decided(accept) → no appeal window → Final × Decided(accept) → the adapter calls `acceptFulfillment` inside the window → Enactment(Adapter8414, accept) = Enacted |
| Variant 1 | Three reject ballots → B1 Decided(reject) → Final × Decided(reject) → the adapter calls `rejectFulfillment` inside the window |
| Variant 2 | At the deadline two accept, one reject → B1 NoDecision(QUORUM_NOT_MET) → Final × NoDecision → the adapter calls nothing; 8414's `claimUnjudged` applies under its own rules |

### 12.2 Case B: a major parameter change under a swarm charter

| Object | Instance |
|---|---|
| Authorization | Governance contract G registers a STANDING_ACCEPTANCE: issue class PARAM_CHANGE; subject = parameter set X with the new value inside the allowed range; accepted policy family F_B versions published by G's constitutional process; filers = any member; disposition = NoDecision → status quo; effects enforced by executor E (48h timelock) authorized by G; validity and caps declared |
| Policy P_B v3 | composition = VETO(target = ALL(Tech, Econ), vetoer = Screening, window = 12h, silence = PASS_THROUGH). Screening: eligibility = the elders' roster, aggregation = K-of-N. Tech: eligibility = credit-qualified profile (8434 Active + 8419 scheme "contract-audit" ≥ 3), selection = SORTITION k = 9 with ≤ 2 per operator, weight = equal, aggregation = {q = 2/3, a = 2/3, 6h confirmation}, resultAcceptance = SIGNED_BALLOTS. Econ: eligibility = members with stake ≥ s and 8434 Active, selection = OPEN, weight = stake-weighted with ≤ 10% per operator, aggregation = {q = 40%, a(τ) falling linearly from 100% to 50% over 72h, s = 25%, 12h confirmation}, resultAcceptance = ON_CHAIN_TALLY. appeal = 1 round, appellant = any member with bond, replacement = Tech redrawn at k = 19, Econ revotes; total cap 10 days; dependencies = the draw's randomness source and the eligibility verifier pinned by address + code hash; update authority = new F_B versions require an ACDF decision under policy P_const; emergency = G's guardian may pause new filings, never in-flight issues |
| Issue I_B | policyId = P_B v3; subject = (G, paramId, newValue); question = adopt the new value?; outcomeSpace = BINARY{adopt, reject}; effectCandidates = {adopt → E.schedule(setParam(X, v))}; bindings = [G, STANDING_ACCEPTANCE(ref)]; effectClass = Binding; disposition = status quo; filer = member M; snapshot = Tech's pool and draw, Econ's weights |
| Bodies | One instance each of Screening, Tech and Econ; new Tech and Econ instances after appeal |
| Main path | Filed → Deciding (verified against the standing acceptance, snapshotted, atomic admission); Screening silent for 12h → PASS_THROUGH; Tech and Econ run in parallel and both Decided(adopt); ALL composes Decided(adopt) → Provisional × Decided(adopt), 48h appeal window → a member appeals with bond → Deciding, round 2 → fresh instances both Decided(adopt) → rounds exhausted → Final × Decided(adopt) → E reads, re-verifies and schedules → E executes after 48h → Enactment(E, adopt) = Enacted |
| Variant 1 | Screening Decided(veto) inside the window → VETO composes Decided(reject, reason VETOED) → Provisional → no appeal → Final × Decided(reject) → no effect |
| Variant 2 | Tech Decided(adopt), Econ participation 35% < 40% at the deadline → Econ NoDecision(QUORUM_NOT_MET) → ALL composes NoDecision ("the required joint approval did not form", naming Econ) → Final × NoDecision → status quo; Tech's adopt remains on record as evidence only |

### 12.3 Comparison

Both cases use exactly the same objects and transitions. Case A's composition is a single body, appeal = 0, CONSUMER_FILED, ON_CHAIN_TALLY; Case B's is VETO over ALL, appeal = 1, STANDING_ACCEPTANCE, mixed acceptance modes. Every difference lives in the policy's component values and the issue's bindings; the state machine and the two-dimensional Result do not change.

[R3] Wording downgraded: this section presents **two design cases worked out**, not "two-ends test passed". The executable counterparts live in reference v0.2: Case A is `test/ACDFAdapter8414.t.sol`, running against the **real** TASK-KERNEL v3.0 `TaskToken` (vendored fixture, source commit `306a8f40`) through acceptance, rejection, NoDecision → `claimUnjudged`, late execution and epoch-exhaustion retry; Case B is `test/ACDFCaseB.t.sol`, running the main path, the veto, the economic chamber missing quorum, and an appeal round's NoDecision keeping the earlier decision. Case B's tests use a **fixed eligibility snapshot and deterministic fixtures**: they prove that composition, appeal and binding mechanics are correct; they do not verify credit verification, sybil resistance or random selection. A genuine "tests passed" still requires the live Sepolia instance with recorded addresses, source version, runtime code, transactions and assertions.

---

## 13. v1 profile list

[R3] "The standard reserves the hook" (Planned / Reserved) is distinguished from "this profile has a verifiable implementation" (Implemented). The first version claims conformance only for Implemented profiles.

| Profile | Nature | Content | v0.2 status |
|---|---|---|---|
| Minimal K-of-N | MUST | Fixed roster, equal weight, K-of-N, single body, no appeal, on-chain tally (7.2) | Implemented (`ACDFRegistry` built-in ROSTER_KOFN + ON_CHAIN_TALLY; 83 truth-table vectors) |
| Body Composition | Normative-optional | ALL / ANY / K-of-M / VETO, four-valued semantics, ordering dependencies (section 8) | Implemented (binary, same candidate effect; parallel bodies + VETO window; 192 truth-table vectors). `after` dependencies and scalar composition: Planned |
| Signed Ballot | Normative-optional | EIP-712 ballot batch acceptance, ERC-1271 contract accounts, same semantics as on-chain tally (7.5) | Implemented (SIGNED_BALLOTS bodies). Signed carriage of result receipts: Planned |
| Authorized Submitter | Normative-optional | Authorized-submitter bodies (8033-style Judge, external DAO votes) (7.5) | Implemented (AUTHORIZED_SUBMITTER bodies) |
| Appeals | Normative-optional | Finite rounds, rebuilding all bodies, appealable-outcome mask, prior decision kept on an undecided appeal (9.2) | Implemented |
| ERC-8414 Adapter | Adapter | Real ABI, both deadlines, one obligation one issue, failure recording and retry (11.1) | Implemented (`ACDFTaskTenderAdapter`, against the real TaskToken fixture) |
| Credit-Qualified Agent | Normative-optional (Finch default) | Complete verification semantics bound to 8419 / 8434 (6.1) | Planned (snapshot production method open, 6.4) |
| Sortition | Normative-optional | Verifiable random draw, weighted draw, growth rules (6.2) | Planned (randomness source open) |
| Arbitration (792 / 1497) | Normative-optional | IArbitrator adapter, Case / Ruling terms (11.3) | Planned (1497-style Evidence events implemented) |
| Executor | Normative-optional | Authorized executor module, execution delay, de-duplication (9.4) | Planned (in v0.2 the relying contract or adapter enforces directly) |
| Optimistic / Challenge | Normative-optional | Default result + challenge eligibility + window + escalation (P7) | Reserved |
| Privacy | Normative-optional | ZK eligibility proofs, anonymous ballots, anti-double-vote identifiers; no coercion-resistance promise (7.7) | Reserved |
| Fees / Bonds | Normative-optional | Filing, participation and appeal bonds, procedural compensation | Reserved (v0.2 moves no funds) |
| Cross-chain | Deferred | Separate disclosure of chain-finality and bridge trust assumptions | Reserved |

---

## 14. Decisions log and open items

### 14.1 Decided (R0 = original requirements, R1 / R2 = advisor review rounds, R3 = advisor implementation review)

| # | Decision | Source |
|---|---|---|
| 1 | Title "Agent Collective Decision Framework"; arbitration is a profile | R1 |
| 2 | One framework ERC: minimal kernel + normative-optional profiles; not split into a set of ERCs initially | R1 |
| 3 | Authorization precedes eligibility; voting creates no power and proves no truth | R1 |
| 4 | Core rule object is the Decision Policy; the authorization relation is Authorization; no Mandate object | R2 |
| 5 | The registry is the normative record; relying contracts enforce effects under constraint; only peripheral copies are mirrors | R2 |
| 6 | The kernel has no generic asset executor; Executor is optional; procedure state / outcome type / enactment status are separate dimensions | R2 |
| 7 | v1 includes policy update rights and version semantics; not full authorization trees, recursive delegation or shared budgets | R2 |
| 8 | On-chain registration and formal result identifiers are the core; 712 / 1271 are optional extensions; no cross-chain claim | R2 |
| 9 | Body composition enters v1 as normative-optional; four-valued semantics; VETO carries time semantics | R2 |
| 10 | NoDecision is committed in advance, bound to the issue, enforced by the relying party; the filer never chooses | R2 |
| 11 | Eligibility rules are mandatory; 8419 / 8434 form the credit-qualified profile, not a hard framework dependency | R1 |
| 12 | Eligibility, selection and weight are separate; eligibility is bound to the matter's domain | R1 |
| 13 | Weight and independence declarations are normalized, algorithms open; control / correlation / interest kept apart | R1 |
| 14 | Finite appeals, explicit finality; human final tier optional; NoDecision legitimate | R1 |
| 15 | Correctness is not majority agreement; results enter KYA as evidence, never edit credit directly; AID lifecycle untouched | R1 |
| 16 | 8414 via adapter without reverse dependency; timing compatibility checked by remaining window and arrival semantics | R1 / R2 |
| 17 | Machine verification is not voting; optimistic confirmation is not θ = 0 | R1 |
| 18 | Polkadot borrowings: division of powers, sources of authority, amendability, dual-threshold curves; not network-security roles as a pipeline | R1 |
| 19 | No claim of an empty field; positioned against 8033 / 8183 / 792 | R1 |
| 20 | K-of-N is the minimal profile and theoretical base; 0-of-0 and 1-of-1 are intuitive metaphors mapping to the verifier path and a single-member body | R0 / R1 |
| 21 | Acceptance modes (A): three modes and Binding / Advisory adopted; POST_ACK becomes file → acknowledge → admit, acknowledgment before voting, Advisory never upgraded | R3 |
| 22 | Minimal K-of-N (B): complementary thresholds and no ballot changes adopted; explicitly an approval rule — no = this proposal blocked, not the opposite proposition established | R3 |
| 23 | Result acceptance (C): three modes in the v1 normative design, not all mandatory; bound to bodies, not whole policies; authorized submission ≠ the registry verified every ballot | R3 |
| 24 | Instantiable parameters (D): pre-declared parameters and setter rights adopted; the setter follows the policy and the authorization relation, not always the consumer; Advisory issues need a lawful setting path too | R3 |
| 25 | Dependency pinning (E): address + code hash + admin allow-list is insufficient; first version = non-upgradeable kernel + fixed-version modules + policy-bound execution configuration; the policy hash binds all execution parameters | R3 |
| 26 | Scalar composition (F): pre-declared intersection of allowed effect sets may come later, a generic min() is rejected; first composition is binary over the same candidate effect | R3 |
| 27 | Withdrawal (G): unilateral withdrawal only while Filed; joint cancellation after admission only as a pre-declared extension | R3 |
| 28 | Clock (H): timestamp default; one clock per registry instance; no block-to-seconds conversion | R3 |
| 29 | Enactment log (I): optional, informative; only the bound consumer or an authorized Executor may report; real reporter recorded; failure never overwrites success | R3 |
| 30 | Abbreviation (J): ACDF, no longer pending | R3 |
| 31 | Files and directories (K): local naming adopted; the submission package is generated by script; 9999 is a working placeholder only; the package converts paths and numbers and removes no normative constraint | R3 |
| 32 | Final is terminal and never replaced by later rounds; Deciding → Final means "no remaining legal procedure"; an appealable NoDecision goes through Provisional first | R3 |
| 33 | New decision: an appeal round without a decision keeps the most recent substantive decision; the NoDecision is recorded separately; Result records sourceRound and roundCount; appeals rebuild all bodies | R3 |
| 34 | VETO never passes early inside its window; a valid veto prevails; the result type is independent of `finalize` ordering | R3 |
| 35 | Time: computation rules are frozen (start instant, total deadline, phase durations, start conditions); the appeal window counts from the result instant; timeout handling covers every non-final state | R3 |
| 36 | 8414 adapter: real ABI; the earlier of both deadlines; resultHash and the cited taskVersion bound; one obligation one issue; no judgmentFee assumption; failures recorded as Failed without touching Final | R3 |
| 37 | Unfinished profiles are marked Planned / Reserved, with no implementation claim; the two narrative cases are not called "tests passed" | R3 |
| 38 | On-chain ballots and authorized-submitter reports name their round (`castBallot(issueId, round, body, approve)`, `submitBodyResult(issueId, round, body, status)`); a mismatch reverts with `ACDF: round mismatch`. Closes the gap between signed and on-chain ballots raised in the first Magicians review (SergeevDmitry): a round-1 transaction included after an appeal opened round 2 is refused, not counted. Interface id of IACDFRegistry becomes 0x843ad5a8 | Magicians review 1 |
| 39 | Obligation identity is separated from subject identity (Magicians review, chugarchugarr): `IssueInput.obligationId` is committed by the consumer (CONSUMER_FILED: required non-zero; STANDING_ACCEPTANCE: fixed in the acceptance or, when zero, derived as keccak256(abi.encode(subject)); POST_ACK: set at acknowledgment); exclusivity key = (consumer, obligationId, question); the full Subject stays frozen on the issue. The 8414 adapter scopes its obligation per submission: keccak256(abi.encode(task, tokenId, submissionId)) | Magicians review 1 |
| 40 | Appeal mode is a required field of the hashed PolicySpec, no kernel default: PRESERVE_UNLESS_OVERTURNED (an appeal round ending in NoDecision leaves the decision under appeal standing) or REQUIRE_FRESH_DECISION (opening an appeal vacates the earlier decision; only the last round's own decision can be adopted, otherwise NoDecision). Security Considerations warn that preserve + a short appeal round lets the clock confirm the challenged result; per-round timing is a reserved extension | Magicians review 1 (chugarchugarr, predge-ai) |
| 41 | Finality by adoption is distinguishable from finality by substantive decision: `Result.adoptedFromEarlierRound` = Decided && sourceRound < roundCount; relying contracts may commit to treat the two differently. Interface ids after revision 2: IACDFPolicyRegistry 0xb362eb4e, IACDFRegistry 0xd31aae30; ACDFRegistry runtime 24,212 B (364 B under EIP-170) | Magicians review 1 (predge-ai) |
| 42 | Editor review of PR #2046 (jochem-brouwer) adopted: RFC 2119/8174 linked; `supportsInterface` listed in the §4/§11 interface blocks (ids unchanged); Test Cases no longer refer to anything outside the proposal's assets; Security Considerations carries no RFC 2119 keywords (each requirement already lives in the Specification); the vendored kernel interface is number-neutral — `ITaskTenderKernel.sol`, adapter comments, revert prefix `ACDFTender:` and the label preimages (`acdf.task-tender.acceptance.v1`, `task-tender.acceptFulfillment`, `task-tender.rejectFulfillment`, `task-tender.noDecision.deferToJudgmentClock`) carry no proposal number. The adapter bytecode changes; registries do not | ERCs editor review |
| 43 | Sepolia revision 2 (2026-10-05 / 2026-10-09): the current registries and adapters are deployed and byte-verified against the assets; Case A (PRESERVE) ends Final x Decided(Yes) and pays through the real `acceptFulfillment`; Case A2 (REQUIRE_FRESH) is appealed, its appeal round closes without ballots and the issue ends Final x NoDecision with the round-1 Yes vacated and `execute` refused. The first attempt, whose Finalize was missed by a day, showed the division of authority at the boundary: the adapter's conservative deadline applies at `open`, the kernel decides at `execute` (it accepted late because `acceptFulfillment` is bounded by `settleBy` only), and `claimUnjudged` paid the NoDecision case — a missed Finalize is a bookkeeping gap, not a loss of funds. Record: `deployments/sepolia-cases.json` | Sepolia revision 2 |

### 14.2 Open before the ERC text

| # | Item | Status | Where |
|---|---|---|---|
| A' | Multi-consumer issues | v0.2 binds one consumer per issue; a required acceptance set and its completion condition are an extension needing an admission-time check | 5.3 |
| B' | Concrete mechanism for instantiable parameters | v0.2 fixes every body and window in the policy; tiering by objective attributes (amount → panel size) needs a setter and range expression | 3.2 |
| C' | Ordering dependencies (`after`) | v0.2 starts all bodies in parallel and expresses screening through the VETO window; explicit screening → review ordering needs window-opening semantics and total-duration computation | 8.3 |
| D' | Typed scalar composition | Intersection rules for the two types "exact amount" and "amount cap" | 8.4 |
| E' | Signed carriage of result receipts | The on-chain record is the core; an EIP-712 receipt is carriage only and needs wording for its correspondence to the record and for "not a cross-chain proof" | 7.5 |
| F' | Fees and bonds | Ownership and distribution of filing, participation and appeal bonds and procedural compensation | 10 |
| G' | Snapshot production and randomness source | Prerequisites for the credit-qualified and sortition profiles | 6.4 |

Later rounds: privacy profile details, deposit rules for Advisory issues, Executor delay and revocation semantics, Case / Ruling mapping for the 792 adapter.

---

## 15. Deliverables, next round, repository layout

### 15.1 Delivered in this round (v0.2)

- Reference implementation: `ACDFPolicyRegistry` (policy families and versions, structural validation, content addressing), `ACDFRegistry` (standing acceptances, three acceptance modes, on-chain tally, signed ballots, authorized submitter, four-valued composition, VETO window, rounds and appeals, finality and hard deadline, informative enactment log, 1497-style evidence events, ERC-6372 clock), `ACDFTaskTenderAdapter` (ERC-8414 adapter). See `assets/erc-acdf/contracts/`.
- Tests: 8 suites, 129 tests under `test/`, covering the six minimum groups required at review (minimal tally, acceptance and freezing, composition, rounds and finality, rules and verification, 8414 execution) plus the executable version of Case B; the 8414 tests run against the vendored real `TaskToken` (task-token-standard commit `306a8f40`). Record in `docs/test-record.md`.
- Vectors: `assets/erc-acdf/vectors/` (`policy-id` and `ballot-digest` generated with ethers v6 and re-derived in Solidity; `kofn-tally` with 83 rows and `composition` with 192 rows generated by an independent JS implementation of the rules and checked row by row in Solidity).
- Schemas: `policy-spec.schema.json`, `result-receipt.schema.json`.

### 15.2 Next round

- `ERCS/erc-acdf.md` is written (Abstract / Motivation / Specification / Rationale / Backwards Compatibility / Test Cases / Reference Implementation / Security Considerations) and passes eipw with the ethereum/ERCs lint configuration, markdownlint and codespell; `scripts/make-filing-package.py` generates and lints the submission package with the 9999 working placeholder. The Ethereum Magicians thread is topic 29850 and `discussions-to` points to it; the pull request is ethereum/ERCs #2046 (branch `add-erc-acdf`, byte-identical to the package); remaining: editor review and the number assignment (`--number <N>` re-generates the package).
- Sepolia: revision 2 done 2026-10-09 (ACDFPolicyRegistry 0x7e870B29C903e71517676d52FCCD20Ef96477A73, ACDFRegistry 0xbA03B451B421b5041d7bE7b5Fd7DbcF3B6Aa1354, adapters 0x09c3550cCAfc2E73B1f0edA3ECA2f5247bB24Da7 / 0x078271c288141660753b1BfB67A3cfc2F06c8AC2) against the live ERC-8414 TaskToken 0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7: Case A (task #13) Final x Decided(Yes) paid through acceptFulfillment; Case A2 (task #14) appealed under REQUIRE_FRESH_DECISION, Final x NoDecision, execute refused. Evidence in `deployments/sepolia-cases.json`; procedure in `docs/sepolia-runbook.md`; the v0.2 run of 2026-10-04 is archived under `deployments/archive/`. Case B (composition, veto) remains a local test case.
- Decide A'–G' of 14.2; among Planned profiles, the credit-qualified agent profile comes first (after the snapshot production method is fixed).
- Ethereum Magicians thread posted (topic 29850); `docs/magicians-post.md` keeps the text.

### 15.3 Repository layout (same structure as task-token-standard / kya-standard / aid-standard)

```
acd-framework/
├── README.md
├── foundry.toml                   # solc 0.8.24, via-IR, optimizer runs 1 (registry 23.4 KB, under EIP-170)
├── package.json                   # ethers 6.17.0, vector generation only
├── docs/
│   ├── design-memo.md             # this file (v0.2)
│   ├── test-record.md             # test record
│   └── magicians-post.md          # Ethereum Magicians thread draft
├── ERCS/
│   └── erc-acdf.md                # ERC-8436 draft text; the submission package is generated by script
├── assets/erc-acdf/
│   ├── contracts/
│   │   ├── ACDFTypes.sol
│   │   ├── ACDFPolicyRegistry.sol
│   │   ├── ACDFRegistry.sol
│   │   ├── interfaces/            # IACDFPolicyRegistry, IACDFRegistry, ITaskTenderKernel
│   │   ├── libraries/             # SignatureChecker (ECDSA + ERC-1271)
│   │   └── adapters/              # ACDFTaskTenderAdapter
│   ├── schemas/                   # policy-spec, result-receipt
│   └── vectors/                   # policy-id, ballot-digest, kofn-tally, composition
├── test/                          # Foundry tests; fixtures/task-token/ = vendored real ERC-8414 contracts
├── tools/                         # vectors.js
├── scripts/                       # make-filing-package.py; Sepolia deployment next
└── deployments/
```

---

## 16. Reference implementation v0.2 and test summary

Toolchain: Foundry forge 1.5.1-stable, solc 0.8.24, via-IR, optimizer runs 1. Runtime sizes: ACDFPolicyRegistry 9,765 B, ACDFRegistry 24,212 B (EIP-170 limit 24,576 B), ACDFTaskTenderAdapter 5,870 B. ERC-165 interface ids: `IACDFPolicyRegistry` 0xb362eb4e, `IACDFRegistry` 0xd31aae30.

| Review test group | Suites | Coverage |
|---|---|---|
| Minimal tally | `ACDFMinimal.t.sol` (26) + `ACDFVectors.t.sol::test_kofn_tally_vectors` (83 rows) | 1-of-1, K = 1, K = N, complementary block threshold, deadline without decision, duplicate member, duplicate ballot, late ballot, illegal thresholds, decision instant, policy hash = execution parameters, family versioning |
| Acceptance and freezing | `ACDFAdmission.t.sol` (21) | Unauthorized bindings; standing-acceptance filer / policy / subject / question constraints; revocation blocks new filings only; POST_ACK acknowledgment before voting; Advisory upgrade attempts; no path to change parameters after admission; unilateral withdrawal after admission refused; duplicate filing of one obligation; consumer-deadline check; evidence events |
| Composition | `ACDFComposition.t.sol` (23) + `ACDFVectors.t.sol::test_composition_vectors` (192 rows) | Pending and NoDecision for ALL / ANY / K-of-M; VETO: no pass before window close, explicit clearance, valid veto, late veto, REQUIRE_CLEARANCE silence, result type independent of call order; authorized submitter overreach, silence, duplicates; duplicate children, back edges, nodes outside the tree, empty graphs, illegal k, body-kind / acceptance mismatch, total-duration coverage |
| Rounds and finality | `ACDFRounds.t.sol` (13) + `ACDFCaseB.t.sol` (5) | Appeals exhausted, appeal of a NoDecision, undecided appeal keeps the earlier result, replay of an old round's signature, Final not replaceable, window anchored to the formation instant, hard-deadline paths from Provisional and Deciding, appeal standing |
| Rules and verification | `ACDFSigned.t.sol` (10) + `ACDFVectors.t.sol` (policy-id, ballot-digest, interface-ids) | Forged / mismatched signatures, high-s and illegal v, one voter twice and contradictory signatures, non-member signatures, batch shape, late signatures, ERC-1271 contract accounts, a later batch cannot rewrite a decided body, EIP-712 domain binding, cross-language encoding agreement |
| 8414 execution | `ACDFAdapter8414.t.sol` (16) | Both deadlines, authority mismatch, non-Pending and machine-path submissions (fixture), one obligation one issue and no re-litigation, reopening after NoDecision, acceptance path with real payout, rejection path releasing the reservation, NoDecision not triggering business default settlement, failure on epoch exhaustion and retry, late execution refused by the kernel with the default taking over, task updates not changing the judged version, duplicate execution |

In total 8 suites and 129 tests pass; the full list and commands are in `docs/test-record.md`. Two limitations are stated plainly: Case B uses a fixed eligibility snapshot and deterministic fixtures, and the Sepolia cases exercise the accept path (Case A) and the appeal-to-NoDecision path (Case A2) with signed ballots only; the reject path, on-chain ballots, authorized submitters and composition are covered by the local suites (`deployments/sepolia-cases.json`).

---

## Appendix A — Glossary (terms fixed for the ERC text)

| Term | Meaning |
|---|---|
| Agent Collective Decision Framework (ACDF) | The framework's formal name |
| Decision Policy | Versioned, content-addressed rule template |
| Policy Family | Links versions and holds the update authority |
| Policy Version / policyId | Immutable; `keccak256(abi.encode(PolicySpec))` |
| Authorization | A relying contract's commitment about which results and effects it accepts |
| Consumer (relying contract) | The party that commits to accept results and enforce effects |
| Standing Acceptance | A relying contract's pre-registered declaration of acceptance |
| Acknowledgment | The relying contract's confirmation in POST_ACK mode |
| Binding | A verified acceptance relation between an issue and a relying contract |
| Issue | The binding object of one concrete decision |
| Subject | The object being decided about |
| Question | The concrete question asked about the subject |
| Outcome Space | The set or range of answers |
| Effect Candidate | The relying-contract action each outcome maps to |
| Effect Class (Binding / Advisory) | With or without acceptance |
| Disposition | The relying party's committed consequence of NoDecision |
| Filer | The account that files the issue |
| Admission | Completion of verification and freezing |
| Snapshot | Eligibility and weights fixed at admission |
| Body | A combination of eligibility + selection + weight + aggregation |
| Body Instance | A body on one issue in one round |
| Body Decision | Pending / Decided / NoDecision |
| Ballot | A participant's vote |
| Eligibility | Who may enter the pool |
| Selection | Who participates this time |
| Weight | How an opinion counts |
| Aggregation / Pass Rule | How ballots become a body decision |
| Participation Threshold (quorum) | q |
| Approval Ratio | a |
| Support Ratio | s |
| Confirmation Period | The duration conditions must hold continuously |
| Composition | Combining several bodies' decisions |
| Combinator (ALL / ANY / K-of-M / VETO) | The composition operators |
| Veto Window | The period in which a veto body may act |
| Round | roundCount = the last round attempted |
| Source Round | sourceRound = the round whose decision was adopted; may differ from roundCount |
| Obligation Key | keccak256(consumer, subject, question); one obligation has at most one unfinished Binding issue |
| Appeal | A review round under the same policy version |
| Procedure State | Filed / Deciding / Provisional / Final / Withdrawn |
| Outcome Type | None / Decided / NoDecision |
| Provisional / Final | Appealable / terminal |
| Result | Procedure state × outcome type |
| Enactment / Enactment Record | Execution and its (informative) record; authoritative at the relying contract |
| Result Acceptance Mode | How a formal result enters the registry |
| Evidence | ERC-1497-style events |
| Executor | An authorized, delayed execution module (optional profile) |
| Adapter | Connects 8414 / 8183 / 792 and similar |
| Profile | A normative-optional configuration |
| Minimal Profile | The MUST configuration |
| Credit-Qualified Agent Profile | Strictly bound to 8419 / 8434 |
| Arbitration Profile | 792 / 1497 compatible; Case / Ruling terms |
| Clock | Declared per ERC-6372 |
| Charter / Grant | Reserved words: charter-type standing acceptance / a concrete grant record; not core objects |

---

## Appendix B — Reference implementation v0.2 interfaces (non-normative; finalized in the ERC text)

Two co-deployed registries and one adapter. Field names follow `assets/erc-acdf/contracts/`.

```solidity
interface IACDFPolicyRegistry {                 // ERC-165 id 0x734a2e40
    function supportsInterface(bytes4) external view returns (bool);
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

interface IACDFRegistry {                       // ERC-165 id 0xd31aae30
    function supportsInterface(bytes4) external view returns (bool);
    function policies() external view returns (IACDFPolicyRegistry);
    // authorization
    function registerStandingAcceptance(StandingAcceptanceInput calldata) external returns (bytes32 acceptanceId);
    function revokeStandingAcceptance(bytes32 acceptanceId) external;
    // issues
    function file(IssueInput calldata) external returns (bytes32 issueId);            // CONSUMER_FILED / STANDING admit atomically; POST_ACK stays Filed
    function acknowledge(bytes32 issueId, bytes32 effectYes, bytes32 effectNo, bytes32 disposition, bytes32 obligationId, uint64 consumerDeadline) external;
    function admitAdvisory(bytes32 issueId) external;
    function expireUnacknowledged(bytes32 issueId) external;
    function withdraw(bytes32 issueId) external;                                      // Filed only, filer only
    function submitEvidence(bytes32 issueId, string calldata evidenceURI) external;    // 1497-style event
    // voting (routed by the body's acceptance mode)
    function castBallot(bytes32 issueId, uint32 round, uint32 body, bool approve) external;
    function submitSignedBallots(bytes32 issueId, uint32 body, address[] calldata voters, bool[] calldata approves, bytes[] calldata signatures) external;
    function submitBodyResult(bytes32 issueId, uint32 round, uint32 body, NodeStatus status) external;
    // rounds and finality
    function settleRound(bytes32 issueId) external;      // records the round when the root is not Pending → Provisional or Final
    function appeal(bytes32 issueId) external;           // within the window, with standing; rebuilds all bodies
    function finalize(bytes32 issueId) external;         // after the appeal window
    function enforceHardDeadline(bytes32 issueId) external;
    // enactment log (informative; bound consumer only)
    function recordEnactment(bytes32 issueId, bytes32 effectId, EnactmentStatus status, bytes32 ref) external;
    // reads
    function getResult(bytes32 issueId) external view returns (Result memory);        // procedure state × outcome type + sourceRound
    function getIssue(bytes32 issueId) external view returns (Issue memory);
    function getRound(bytes32 issueId, uint32 round) external view returns (RoundState memory);
    function getBodyState(bytes32 issueId, uint32 round, uint32 body) external view returns (BodyState memory);
    function bodyStatus(bytes32 issueId, uint32 round, uint32 body) external view returns (NodeStatus, Reason, uint64 at);
    function nodeStatus(bytes32 issueId, uint32 round, uint32 node) external view returns (NodeStatus, Reason, uint64 at);
    function hasVoted(bytes32 issueId, uint32 round, uint32 body, address voter) external view returns (bool);
    function activeIssueOf(address consumer, bytes32 obligationKey) external view returns (bytes32);
    function obligationKeyOf(address consumer, bytes32 obligationId, bytes32 question) external pure returns (bytes32);
    function getEnactment(bytes32 issueId, address consumer, bytes32 effectId) external view returns (Enactment memory);
    function ballotDigest(bytes32 issueId, uint32 round, uint32 body, address voter, bool approve) external view returns (bytes32);
    function clock() external view returns (uint48);         // ERC-6372
    function CLOCK_MODE() external view returns (string memory);
}

contract ACDFTaskTenderAdapter {          // ERC-8414 acceptanceAuthority backed by one ACDF policy
    function open(uint256 tokenId, uint256 submissionId) external returns (bytes32 issueId);  // permissionless trigger; the adapter files as consumer
    function execute(bytes32 issueId) external;                                             // Final × Decided → acceptFulfillment / rejectFulfillment
}
```

State machine (v0.2): `Filed → Deciding → (Provisional ⇄ Deciding)* → Final`, plus `Filed → Withdrawn`. Outcome type `None / Decided / NoDecision` and enactment status `NotEnacted / Enacted / Failed` are recorded independently.

---

## Appendix C — What is borrowed from where

| Source | Borrowed | Lands in | Not borrowed |
|---|---|---|---|
| Polkadot OpenGov | Origins / Tracks tiering by objective attributes; Approval / Support thresholds with confirmation period; Fellowship-style elders; amendability of institutions | 3.2 instantiable, 7.3, 8.2 VETO, 5.5 | Collator / Validator / Nominator / Fisherman as a governance pipeline (the independent Fisherman role was dropped upstream) |
| Polkadot NPoS | Nominators sharing the slashing of those they back | 6.2 guarantees (with scope, validity, cap, triggers) | Unlimited lending of credit |
| Kleros | Sortition, appeal with panel growth (2k + 1), 792 / 1497 interfaces | 6.2 SORTITION, 9.2, 11.3 | "Agreeing with the majority is correct" as a default incentive |
| OpenZeppelin Governor / Timelock | Separation of decision and execution; execution delay | 9.4, Executor profile | Token weight as the only weight |
| Safe | Fixed-roster K-of-N | 7.2 minimal profile | — |
| UCAN / Zodiac / AccessManager | Attenuated authorization, authorized executor modules, delayed role permissions | 5.4 non-expansion, Executor profile | A full authorization tree in the v1 kernel |
| ERC-8033 | Authorized-submitter aggregation plus a dispute round | 7.5 AUTHORIZED_SUBMITTER | A single Judge as the framework default |
| ERC-8419 KYA | Registry + descriptor JSON; authoritative registry + lossy mirror bridge | 3.2, 11.4 | Demoting the registry to a mirror |
| MACI | Privacy and coercion resistance handled separately | 7.7 | Promising coercion resistance in the name of ZK |
