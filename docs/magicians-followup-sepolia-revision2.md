# Magicians follow-up: revision 2 on Sepolia (two live cases, one appeal)

Follow-up for topic 29850 (draft; post as one reply after the reply to #4/#5).

---

**Revision 2 is on Sepolia, and this time the appeal path ran for real.** The contracts are the ones in PR #2046 (consumer-committed `obligationId`, policy-explicit `appealMode`, round-bound ballots, the editor's renames); I compared the deployed runtime of all four with a fresh build of the assets, byte for byte outside the immutable slots.

| Contract | Sepolia |
|---|---|
| `ACDFPolicyRegistry` | `0x7e870B29C903e71517676d52FCCD20Ef96477A73` |
| `ACDFRegistry` | `0xbA03B451B421b5041d7bE7b5Fd7DbcF3B6Aa1354` |
| `ACDFTaskTenderAdapter`, policy A (PRESERVE_UNLESS_OVERTURNED) | `0x09c3550cCAfc2E73B1f0edA3ECA2f5247bB24Da7` |
| `ACDFTaskTenderAdapter`, policy A2 (REQUIRE_FRESH_DECISION) | `0x078271c288141660753b1BfB67A3cfc2F06c8AC2` |

The relying contract is the live ERC-8414 reference `TaskToken` (`0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`); each adapter is the `acceptanceAuthority` of one task and files a CONSUMER_FILED Binding issue scoped to `obligationId = keccak256(task, tokenId, submissionId)`. Five jurors, signed-ballot 3-of-5, appeal window 600 s, standing ANYONE.

**Case A — task #13, issue `0xf2e88a4e…1dc8`, PRESERVE.** One dissent and three approvals in one signed batch, `settleRound` → Provisional(Yes), the appeal window passed with no appeal, `finalize` → Final × Decided(Yes), `adoptedFromEarlierRound = false`; the adapter's `execute` called the real `acceptFulfillment(13, 1)` and the worker was paid. `getResult`: decidedAt 1791526056 (the block of the third approval), finalAt 1791527052.

**Case A2 — task #14, issue `0x2ff1ec2f…4cdc`, REQUIRE_FRESH.** Three approvals, `settleRound` → Provisional(Yes); the deployer account appealed; round 2 (900 s) received no ballots and settled NoDecision(QUORUM_NOT_MET) → Final × NoDecision, `roundCount 2`, `sourceRound 2`, `adoptedFromEarlierRound = false`. The round-1 Yes is on chain (three `BallotCast`, `RoundSettled(1)`) and vacated. The adapter refuses `execute` (`ACDFTender: no decision; judgment clock governs`), the submission is still Pending at the kernel, and nothing in ACDF touches the escrow: after the tender's two-day judgment window `claimUnjudged(14, 1)` is the kernel's own default. Under PRESERVE the very same transactions would have produced Final × Decided(Yes) with `adoptedFromEarlierRound = true` — which is the whole point of putting the mode inside the hashed policy.

**A missed Finalize, and what it showed.** A first attempt on 2026-10-05 (tasks #9/#10, same registries and policies, earlier adapter build) opened both cases but Finalize was not run before the tender's judgment window closed. Closing it a day late was instructive: the registry side finalized exactly as it would have on time; Case A's late `execute` was still accepted by the kernel, because `acceptFulfillment` is bounded by `settleBy` only and this tender has `settleBy = 0`; and Case A2's submission was paid by `claimUnjudged`. So the boundary behaves as decision #36 intended: the adapter's conservative deadline (judgment window minus margin) applies when it files, the kernel alone decides whether a late enactment is legal and the adapter records Enacted or Failed, and a NoDecision leaves the relying contract's own default in force. A missed Finalize is a bookkeeping gap, not a loss in either direction.

One operational note for anyone replaying this: Sepolia repriced between the two attempts (base fee a few wei, block gas limit 200M, contract creation about seven times the local estimate), and transactions sized by Foundry's local simulation ran out of gas while the simulation passed. `forge script … --skip-simulation --gas-estimate-multiplier 150` (node-side estimation) fixed it; the runbook says so.

Everything — every transaction with block, timestamp and gas, the decoded `getResult` of both issues, the first attempt, the superseded contracts — is in `deployments/sepolia-cases.json` of the reference repository; `docs/sepolia-runbook.md` has the four commands and the two for a missed Finalize.

Next: Case B (composition with a veto body, on-chain ballots) stays a local test case for now; I would rather spend the next Sepolia run on whatever this thread finds wrong first.
