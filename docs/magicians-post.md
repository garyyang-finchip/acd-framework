# Ethereum Magicians post

**Posted:** https://ethereum-magicians.org/t/draft-erc-agent-collective-decision-framework-acdf-authorized-composable-collective-decisions-with-procedural-finality/29850 (topic 29850, 2026-10-04)

**Category:** ERCs
**Suggested title:** [Draft ERC] Agent Collective Decision Framework (ACDF) — authorized, composable collective decisions with procedural finality

---

Hi all,

This is a draft ERC for an **Agent Collective Decision Framework (ACDF)**: two co-deployable registries through which qualified participants — agents, humans or contracts — form collective decisions with a defined effect, within explicit authorization, under rules that are frozen as the very parameters the registry executes.

Repository (design memo, reference implementation, tests, vectors): https://github.com/garyyang-finchip/acd-framework
ERC text: `ERCS/erc-acdf.md` in that repository (PR to ethereum/ERCs to follow; link will be added here).

## The slot this fills

Several agent-economy standards stop at a single trusted address at exactly the point where a *decision* is needed: ERC-8183's `evaluator`, the `acceptanceAuthority` of the token-bound task tender draft (ERC-8414), an arbitrator in the ERC-792 lineage. ERC-8033 standardizes one specific council flow for information queries. Governors assume one electorate and one weighting; a Safe gives a roster a K-of-N threshold but has no notion of a question, a result record or a procedure that can end *without* a decision.

ACDF is the thing those slots are waiting for: one interoperable record of **which rule** decided **which question** about **which subject**, **who had committed in advance** to accept the result, whether the procedure is open, provisional or final, and whether it ended in a decision at all.

## What it specifies

- **Decision Policy** — an immutable, content-addressed `PolicySpec` (`policyId = keccak256(abi.encode(spec))`): bodies, thresholds, composition graph, windows, appeal rules. The rule as published and the rule as executed are the same object; no proxy / admin-list / code-hash argument needed. Versions are linked through a *policy family* whose update authority alone publishes the next version; publishing never touches issues bound to earlier versions.
- **Issue** — one concrete decision: subject + question + policy version + at most one *consumer* (relying contract). Three acceptance modes, all of them acts of the consumer: `CONSUMER_FILED` (the relying contract files), `STANDING_ACCEPTANCE` (it pre-declares what it accepts; listed filers file within that), `POST_ACK` (anyone files, the named consumer must acknowledge **before** admission and voting — otherwise the issue proceeds only as *Advisory*, and an Advisory issue can never be upgraded). One unfinished Binding issue per `(consumer, subject, question)`: no verdict shopping.
- **Bodies** — fixed-roster K-of-N (on-chain ballots, or EIP-712 signed ballots relayed by anyone, ERC-1271 for contract voters, no nonce — identity is the only key) and authorized submitters. **Composition** with `ALL / ANY / K-of-M / VETO` under **four-valued** semantics (Pending / Yes / No / NoDecision): two chambers compose by logic, never by pooling ballots, and a live veto window can never be extinguished by an early settlement.
- **Finality** — procedure state (`Filed → Deciding → Provisional → Final`), outcome type (`None / Decided / NoDecision`) and enactment status are three separate dimensions. Final is terminal. Appeals rebuild all bodies under the same policy; an appeal round that fails to reach quorum **keeps** the decision being appealed (`sourceRound` ≠ `roundCount`). Appeal windows run from the instant the ballots determined the result, not from the settlement transaction.
- **No execution in the kernel** — the registry never moves assets. Relying contracts read `Final × Decided` and enforce their own committed effects; a `NoDecision` triggers only the disposition the consumer committed to in advance (for a task tender: nothing — the tender's own "silence pays the fulfiller" default governs).

Minimal conformance is a fixed-roster K-of-N vote. Composition, signed ballots, authorized submitters and appeals are normative-optional profiles over the same objects. Eligibility profiles (e.g. ERC-8004 identities with KYA-style trust assertions, ERC-8419 / ERC-8434 in my other drafts), sortition, weighting, non-binary outcomes, executors, fees, privacy and cross-chain carriage are explicitly **reserved**, not specified.

## What exists today

- Reference implementation (Solidity 0.8.24, non-upgradeable): `ACDFPolicyRegistry` (9.6 KB), `ACDFRegistry` (23.5 KB, under EIP-170 with via-IR), `ACDFTaskTenderAdapter`.
- 119 Foundry tests in 8 suites covering: minimal tally edge cases and policy validation; acceptance modes, freezing, withdrawal and the obligation rule; every composition branch incl. "result independent of settlement order"; rounds, appeals, adoption rule, hard deadlines, replay of earlier-round signatures; signed-ballot verification incl. ERC-1271 and malleable signatures; and an end-to-end adapter run against the **vendored real** task-tender kernel (accept pays the worker, reject releases the reservation, NoDecision leaves `claimUnjudged` in force, late execution refused by the kernel, retry after an epoch-pacing refusal).
- Cross-language vectors: `policyId` and EIP-712 digests produced with ethers v6 and re-derived in Solidity; 83-row K-of-N and 192-row composition truth tables generated by an independent JS implementation of the rules.

Not yet: a Sepolia deployment. It is next, and I will post addresses, source version, runtime code and the transactions of the end-to-end case here when it is done. Until then the two worked cases in the memo are "design cases worked out", not "tested on-chain".

## Questions I would value feedback on

1. **Obligation granularity.** The kernel keys "one live binding issue" on `(consumer, subject, question)`. Is that the right level, or should the kernel also fix the business key inside `subject.dataHash` rather than leaving it to the adapter?
2. **Adoption rule on appeal.** When an appeal round ends in NoDecision, the earlier substantive decision is adopted. The alternative ("re-hearing cancels the earlier result") is left to a future explicit configuration. Objections?
3. **VETO semantics.** An approve ballot in the veto body means veto, an explicit block means clearance, silence means pass-through or no-clearance per policy, and the node stays Pending while the window is open regardless of the target. Is anything missing for the screening-council use case?
4. **Signed ballots without a nonce.** De-duplication is per (issue, round, body, voter); a second signature is worthless by construction. Is there a case where a nonce is still needed?
5. **Eligibility.** The kernel only requires rosters to be fixed and frozen at admission. Would reviewers rather see an eligibility profile (identity + trust assertions, operator caps, conflict exclusion) in this ERC, or kept separate as planned?

Thanks — Gary
