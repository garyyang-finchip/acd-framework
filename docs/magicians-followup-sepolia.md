# Magicians follow-up: Sepolia deployment and Case A

Reply to post in topic 29850 (draft; post as a reply, not an edit of the first post).

---

**Sepolia deployment and the first live case**

The reference implementation is now on Sepolia, and one real submission on the live ERC-8414 task tender (the token-bound task tender draft's reference `TaskToken`, `0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`) has gone through the whole procedure.

Contracts (solc 0.8.24, via-IR, optimizer runs 1; runtime code byte-identical to the repository build):

- `ACDFPolicyRegistry` `0x8b454635ad6CBd7649418df73776ED9FbD39f668`
- `ACDFRegistry` `0x9ef9b6c68b2de3aCdaB42fbeca326816D1316a69`
- `ACDFTaskTenderAdapter` `0x76986Fd0Cc636Bf4C54A2F9145463F9893b9635F`
- policy v1 `0x0f36cb699dafbdab0b08057665b6a716316e730409f5cbdfe53a5241f99ff279` — family `keccak256("acdf.sepolia.case-a")`, one body: fixed roster of five, 3-of-5, EIP-712 signed ballots, one appeal, 10-minute appeal window, 3-hour hard cap

Case A, blocks 11844486–11844663 (2026-10-04):

1. Task #8 minted on the live TaskToken with the adapter as `acceptanceAuthority`; 0.001 ETH escrowed, one completion, 2-day judgment window.
2. The worker submitted; `adapter.open(8, 1)` filed a Binding CONSUMER_FILED issue (`0xa5898a1a…bc4df`) bound to the exact submission (`resultHash`, cited `taskVersion`) and to `submittedAt + judgmentWindow − margin` as the consumer deadline; the registry admitted it with a hard cap of 3 hours inside that deadline.
3. Four signed ballots relayed in one transaction: one No, then three Yes. The body decided Yes at the arrival of the third approval; the dissent is on record.
4. `settleRound` → Provisional. The appeal window ran from the decision instant (block 11844525), not from the settlement transaction (block 11844526).
5. After the window: `finalize` → Final × Decided(Yes), `sourceRound = roundCount = 1`. `adapter.execute` called the real `acceptFulfillment`; the kernel paid the 0.001 ETH reward to the worker, and the registry recorded the enactment as Enacted. The registry itself never touched the escrow.

Every transaction, event and assertion: `deployments/sepolia.json` and `deployments/sepolia-case-a.json` in the repository; the four `forge script` runs are in `script/SepoliaCaseA.s.sol` with `docs/sepolia-runbook.md`, so anyone can repeat the case with their own accounts. Total: 13 transactions, 11.3M gas.

What this does and does not show: the accept path of the ERC-8414 adapter and the signed-ballot profile are now exercised on a public network against the real kernel. The reject path, NoDecision with the tender's own `claimUnjudged` clock taking over, composition, veto windows and appeals remain covered by the 119 local tests only. The policy family's update authority currently sits with the deployer account; a later policy version can move it.

Feedback on the five questions in the first post is still what I am most after — in particular the obligation key granularity and the adoption rule on appeal.
