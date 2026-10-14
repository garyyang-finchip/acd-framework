# Magicians follow-up: revision 3 on Sepolia (composition, on-chain ballots, reject path; validating registries)

Follow-up for topic 29850 (draft; post after the merge announcement and the reply to #9/#10).

---

**Revision 3 is on Sepolia.** It closes the gaps between what the local suites cover and what had run on a public network: the registries now carry the body-role validation from #10, one case composes three bodies with a veto and on-chain ballots, and one case takes the reject path. Same live ERC-8414 `TaskToken` (`0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`), same account set, same scripts style (`script/SepoliaCaseBC.s.sol`, four runs).

| Contract | Sepolia |
|---|---|
| `ACDFPolicyRegistry` (with the body-role rules) | `0x7eAfCC452EC0A60a358a26B6e73f28413C4abeF0` |
| `ACDFRegistry` | `0x3bE57E74f2E7c280073b6B16A1Db3F562758dB01` |
| `ACDFTaskTenderAdapter`, policy B | `0x19B8E0290456fCd771169D6AEdc9e1D771Da426f` |
| `ACDFTaskTenderAdapter`, policy C | `0x0Ef78bddBcf96919B27df84c091a34DfDF4D820b` |

All four match a fresh build of the assets byte for byte outside the immutable slots.

**The body-role rules, observable on chain.** @Revinand an `eth_call` offering your second tree (the veto body also a `BODY` leaf under the `VETO` it guards) to the new policy registry reverts with `ACDF: veto body votes`; the same call against the revision-2 registry (`0x7e870B29…7A73`) returns a policy id, which is exactly the gap you pointed at. Nothing was sent; the two registries' answers are in the record.

**Case B — task #15, issue `0x8e06e840…7524`: `VETO(screening) → ALL(technical, economic)`.** Three bodies: a screening body (jurors 4-5, 1-of-2, signed ballots, 15-minute window, `REQUIRE_CLEARANCE`) and two chambers (jurors 1-3 and 3-5, 2-of-3 each, one-hour windows, on-chain ballots). The screening body blocked twice in one signed batch — explicit clearance — and the four chamber members each sent their own `castBallot(issue, round 1, body, Yes)`; this is the first time on-chain ballots and composition ran outside the local suites. `settleRound` found the root `Yes` at the fourth ballot, 828 s before the veto window would have closed: explicit clearance lets the target pass early, and the `VETO` node never held the result hostage. Appeal window passed, `finalize` → Final × Decided(Yes), `execute` → `acceptFulfillment(15, 1)` paid the worker. The `BallotCast` events show the two acceptance paths side by side (`signed: true` for the screening body, `false` for the chambers) under one counting rule.

**Case C — task #16, issue `0x79552e1d…d554`: the reject path.** The 3-of-5 policy of Case A, a deliverable that answers a different question, three signed `No` ballots: `n − k + 1` blocks, so the body decides `No` (the approval rule failed, not "the opposite was proven" — the adapter maps `No` to `rejectFulfillment` because that is the consumer's own committed `effectNo`). Final × Decided(No), `execute` → `rejectFulfillment(16, 1)`: the submission is `Rejected`, `pendingOf` is back to 0, the 0.001 ETH escrow is untouched, nothing was credited to the worker.

What is still local-only is so by construction of this adapter, which files as `CONSUMER_FILED`: `STANDING_ACCEPTANCE`, `POST_ACK` and `AUTHORIZED_SUBMITTER` bodies need a different relying contract, and an *exercised* veto (an approve ballot in the screening body) is in the suites but not on chain yet. Everything above — every transaction with block, timestamp and gas, the decoded `getResult` and `getRound` reads, the kernel's submission records — is under `revision3` in `deployments/sepolia-cases.json` of the reference repository; `docs/sepolia-runbook.md` has the commands.
