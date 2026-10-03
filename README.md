# Agent Collective Decision Framework (ACDF)

> Qualified participants form collective decisions with defined effect, within explicit authorization, under verifiable and composable rules.
>
> 让有资格的参与者，在明确的授权范围内，按照可验证、可组合的规则，形成具有明确效力的共同决定。

**Status:** design memo v0.2 + reference implementation v0.2 (Solidity, Foundry), 117 passing tests, cross-language vectors. The English ERC text and the Sepolia run against the live ERC-8414 contract are the next round. Nothing here is deployed yet.

## What it is

A minimal interoperable kernel for collective decisions among agents, plus normative-optional profiles. In four clauses: decision policies organize the deliberating bodies; authorization bounds the effect; the registry holds the normative record; adapters connect to execution.

- A **Decision Policy** is an immutable, content-addressed template: `policyId = keccak256(abi.encode(PolicySpec))`. Every parameter that drives eligibility, thresholds, composition, timing and finality is inside the hashed object, so the registered rule and the executed rule are the same thing. Versions are linked through a policy family whose update authority alone may publish the next version; publishing never changes what existing issues are bound to.
- An **Issue** binds a subject + question + policy version + at most one consumer. Three acceptance modes: `CONSUMER_FILED` (the relying contract files), `STANDING_ACCEPTANCE` (the relying contract pre-declares what it accepts; listed filers file within it), `POST_ACK` (anyone files, the named consumer must acknowledge before admission; otherwise Advisory or closed). One live binding issue per obligation.
- **Bodies** vote inside rounds. v0.2 ships two built-in kinds — fixed-roster K-of-N (on-chain ballots or EIP-712 signed ballots with ERC-1271 support) and authorized submitter — and composes them with `ALL / ANY / K-of-M / VETO` under four-valued semantics (Pending / Yes / No / NoDecision). A live veto window can never be extinguished by an early settlement.
- **Results** keep three dimensions apart: procedure state (`Filed → Deciding → Provisional → Final`, plus `Withdrawn`), outcome type (`None / Decided / NoDecision`) and enactment status (per consumer and effect; authoritative at the consumer). Final is terminal. An appeal round that ends in NoDecision keeps the previous substantive decision (`sourceRound` ≠ `roundCount`).
- The kernel never executes external effects. `ACDFTaskTenderAdapter` shows the pattern for ERC-8414: it is the task's acceptance authority, files issues bound to the exact submission and to both 8414 clocks (judgment window and `settleBy`), and executes Final decisions through the real `acceptFulfillment` / `rejectFulfillment`; a NoDecision triggers nothing — 8414's own `claimUnjudged` governs.

## Repository

```
docs/design-memo-zh.md        design memo v0.2 (Chinese) — principles, object model, state machine, decisions log
docs/test-record.md           toolchain, sizes, full test list, stated limitations
assets/erc-acdf/contracts/    ACDFTypes, ACDFPolicyRegistry, ACDFRegistry, interfaces/, libraries/, adapters/
assets/erc-acdf/schemas/      policy-spec.schema.json, result-receipt.schema.json
assets/erc-acdf/vectors/      policy-id, ballot-digest (ethers v6 ↔ solc), kofn-tally, composition truth tables
test/                         Foundry suites; test/fixtures/task-token/ = vendored real ERC-8414 kernel (commit 306a8f40)
tools/vectors.js              regenerates the vectors
ERCS/                         erc-acdf.md — next round
```

## Build and test

```bash
forge install foundry-rs/forge-std   # once; lib/ is not vendored
forge build
forge test
npm install && node tools/vectors.js # optional: regenerate vectors
```

`foundry.toml` pins solc 0.8.24 with via-IR and optimizer runs = 1; the issue registry is 23,400 bytes of runtime code, under the EIP-170 limit.

## Profiles in v0.2

Implemented: Minimal K-of-N (MUST), Body Composition (binary, same candidate effect), Signed Ballots, Authorized Submitter, Appeals, ERC-8414 adapter. Planned: Credit-Qualified Agent (ERC-8419 / ERC-8434), Sortition, Arbitration (ERC-792 / 1497), Executor. Reserved: Optimistic / Challenge, Privacy, Fees / Bonds, Cross-chain. The framework reserves the hooks; only Implemented profiles claim a verifiable implementation.

## Position in the standards family

ERC-8434 AID identifies the subject; ERC-8419 KYA expresses and verifies trust conditions; ACDF organizes authorized collective decisions; applications such as ERC-8414 Task Tenders execute their own committed consequences.

Related: ERC-8338, ERC-8414, ERC-8419, ERC-8434. Prior art positioned against: ERC-792 / ERC-1497, ERC-8033, ERC-8183, ERC-8226, OpenZeppelin Governor / Timelock, Safe, Kleros, Polkadot OpenGov.

## License

CC0-1.0 for the specification text and the reference assets, as required by EIP-1 for ERC submissions.
