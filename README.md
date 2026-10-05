# Agent Collective Decision Framework (ACDF)

> Qualified participants form collective decisions with defined effect, within explicit authorization, under verifiable and composable rules.

**Status:** design memo v0.2, reference implementation v0.2 (Solidity, Foundry), 121 passing tests, cross-language vectors, and the draft ERC text (`ERCS/erc-acdf.md`) under discussion on Ethereum Magicians (https://ethereum-magicians.org/t/draft-erc-agent-collective-decision-framework-acdf-authorized-composable-collective-decisions-with-procedural-finality/29850) and submitted to ethereum/ERCs as pull request #2046 (https://github.com/ethereum/ERCs/pull/2046; working number 9999 until an editor assigns one). Deployed on Sepolia on 2026-10-04 and exercised end to end against the live ERC-8414 TaskToken (Case A, see below).

## What it is

A minimal interoperable kernel for collective decisions among agents, plus normative-optional profiles. In four clauses: decision policies organize the deliberating bodies; authorization bounds the effect; the registry holds the normative record; adapters connect to execution.

- A **Decision Policy** is an immutable, content-addressed template: `policyId = keccak256(abi.encode(PolicySpec))`. Every parameter that drives eligibility, thresholds, composition, timing and finality is inside the hashed object, so the registered rule and the executed rule are the same thing. Versions are linked through a policy family whose update authority alone may publish the next version; publishing never changes what existing issues are bound to.
- An **Issue** binds a subject + question + policy version + at most one consumer. Three acceptance modes: `CONSUMER_FILED` (the relying contract files), `STANDING_ACCEPTANCE` (the relying contract pre-declares what it accepts; listed filers file within it), `POST_ACK` (anyone files, the named consumer must acknowledge before admission; otherwise Advisory or closed). One live binding issue per obligation.
- **Bodies** vote inside rounds. v0.2 ships two built-in kinds — fixed-roster K-of-N (on-chain ballots or EIP-712 signed ballots with ERC-1271 support) and authorized submitter — and composes them with `ALL / ANY / K-of-M / VETO` under four-valued semantics (Pending / Yes / No / NoDecision). A live veto window can never be extinguished by an early settlement.
- **Results** keep three dimensions apart: procedure state (`Filed → Deciding → Provisional → Final`, plus `Withdrawn`), outcome type (`None / Decided / NoDecision`) and enactment status (per consumer and effect; authoritative at the consumer). Final is terminal. An appeal round that ends in NoDecision keeps the previous substantive decision (`sourceRound` ≠ `roundCount`).
- The kernel never executes external effects. `ACDFTaskTenderAdapter` shows the pattern for ERC-8414: it is the task's acceptance authority, files issues bound to the exact submission and to both 8414 clocks (judgment window and `settleBy`), and executes Final decisions through the real `acceptFulfillment` / `rejectFulfillment`; a NoDecision triggers nothing — 8414's own `claimUnjudged` governs.

## Repository

```
ERCS/erc-acdf.md              draft ERC text (working placeholder number 9999; filed via scripts/make-filing-package.py)
docs/design-memo.md           design memo v0.2 — principles, object model, state machine, decisions log
docs/test-record.md           toolchain, sizes, full test list, stated limitations
docs/magicians-post.md        draft of the Ethereum Magicians thread
assets/erc-acdf/contracts/    ACDFTypes, ACDFPolicyRegistry, ACDFRegistry, interfaces/, libraries/, adapters/
assets/erc-acdf/schemas/      policy-spec.schema.json, result-receipt.schema.json
assets/erc-acdf/vectors/      policy-id, ballot-digest (ethers v6 ↔ solc), kofn-tally, composition truth tables, interface-ids
test/                         Foundry suites; test/fixtures/task-token/ = vendored real ERC-8414 kernel (commit 306a8f40)
tools/vectors.js              regenerates the vectors
scripts/make-filing-package.py  builds and lints the ethereum/ERCs submission package (ERCS/erc-N.md + assets/erc-N/)
script/SepoliaCaseA.s.sol     Foundry scripts: Sepolia deployment and Case A against the live ERC-8414 TaskToken
docs/sepolia-runbook.md       how to run them; what each run proves
deployments/                  sepolia.json (addresses, policy), sepolia-case-a.json (every transaction and event), case-a/ (hashed documents)
```

## Build and test

```bash
forge install foundry-rs/forge-std   # once; lib/ is not vendored
forge build
forge test
npm install && node tools/vectors.js # optional: regenerate vectors
```

`foundry.toml` pins solc 0.8.24 with via-IR and optimizer runs = 1; the issue registry is 23,626 bytes of runtime code, under the EIP-170 limit. ERC-165 ids: `IACDFPolicyRegistry` `0x734a2e40`, `IACDFRegistry` `0x843ad5a8`.

## Sepolia deployment

| Contract | Address |
|---|---|
| ACDFPolicyRegistry | `0x8b454635ad6CBd7649418df73776ED9FbD39f668` |
| ACDFRegistry | `0x9ef9b6c68b2de3aCdaB42fbeca326816D1316a69` |
| ACDFTaskTenderAdapter | `0x76986Fd0Cc636Bf4C54A2F9145463F9893b9635F` (acceptance authority for task #8 on the live ERC-8414 TaskToken `0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`) |
| Policy v1 | `0x0f36cb699dafbdab0b08057665b6a716316e730409f5cbdfe53a5241f99ff279` (family `keccak256("acdf.sepolia.case-a")`, 3-of-5 signed ballots, one appeal, 10-minute window) |

Case A ran on 2026-10-04 (blocks 11844486-11844663): the worker's submission #1 on task #8 was filed by the adapter as a Binding CONSUMER_FILED issue (`0xa5898a1a...bc4df`), four EIP-712 signed ballots (one No, three Yes) were relayed in one transaction, round 1 settled Yes at the instant of the third approval, the ten-minute appeal window passed, `finalize` recorded Final x Decided(Yes) with `sourceRound = roundCount = 1`, and `adapter.execute` paid the 0.001 ETH reward to the worker through the real `acceptFulfillment`. Every address, transaction, event and assertion is in `deployments/sepolia.json` and `deployments/sepolia-case-a.json`. The policy family's update authority is currently the deployer account.

`docs/sepolia-runbook.md` describes the four `forge script` runs (`script/SepoliaCaseA.s.sol`) that deploy `ACDFPolicyRegistry`, `ACDFRegistry` and `ACDFTaskTenderAdapter` on Sepolia and take one real submission on the live ERC-8414 TaskToken (`0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`) from filing through signed ballots, settlement, the appeal window, finality and execution. The sequence was rehearsed on a local Anvil chain against the vendored kernel before the Sepolia run.

## Filing

```bash
python3 scripts/make-filing-package.py --discussions https://ethereum-magicians.org/t/<thread>/<id>
# -> ercs-pr-package/ERCS/erc-9999.md and ercs-pr-package/assets/erc-9999/ ; the script lints the package
# after an editor assigns a number:
python3 scripts/make-filing-package.py --number <N> --discussions https://ethereum-magicians.org/t/<thread>/<id>
```

The ERC text refers to unmerged companion drafts descriptively and links only to merged proposals; the script rejects literal references to unmerged numbers, external URLs, Chinese characters, missing first-mention links and broken asset links.

## Profiles in v0.2

Implemented: Minimal K-of-N (MUST), Body Composition (binary, same candidate effect), Signed Ballots, Authorized Submitter, Appeals, ERC-8414 adapter. Planned: Credit-Qualified Agent (ERC-8419 / ERC-8434), Sortition, Arbitration (ERC-792 / 1497), Executor. Reserved: Optimistic / Challenge, Privacy, Fees / Bonds, Cross-chain. The framework reserves the hooks; only Implemented profiles claim a verifiable implementation.

## Position in the standards family

ERC-8434 AID identifies the subject; ERC-8419 KYA expresses and verifies trust conditions; ACDF organizes authorized collective decisions; applications such as ERC-8414 Task Tenders execute their own committed consequences.

Related: ERC-8338, ERC-8414, ERC-8419, ERC-8434. Prior art positioned against: ERC-792 / ERC-1497, ERC-8033, ERC-8183, ERC-8226, OpenZeppelin Governor / Timelock, Safe, Kleros, Polkadot OpenGov.

## License

CC0-1.0 for the specification text and the reference assets, as required by EIP-1 for ERC submissions.
