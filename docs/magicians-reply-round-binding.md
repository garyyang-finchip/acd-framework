# Magicians reply: round binding for on-chain ballots

Reply to SergeevDmitry in topic 29850 (draft; post as a reply).

---

@SergeevDmitry Thank you — the scenario is real and the fix is the one you describe.

The gap: a signed ballot is bound to its round by the EIP-712 digest, so a round-1 signature can never be accepted in round 2. An on-chain `castBallot` had no such binding. A voter who broadcast during round 1 while the remaining ballots settled the round and an appeal opened round 2 would have had the pending transaction counted in round 2 — and because ballots cannot be changed, there would have been no way to undo it. The two acceptance paths were supposed to share one rule and did not.

Change (now in the reference repository and pushed to PR #2046):

- `castBallot(bytes32 issueId, uint32 round, uint32 body, bool approve)` — the registry requires `round == roundCount` and reverts with `ACDF: round mismatch` otherwise.
- `submitBodyResult(bytes32 issueId, uint32 round, uint32 body, NodeStatus status)` — same rule for authorized-submitter reports, which had the same exposure.
- Spec text: Sections 7.2 and 7.4 state the requirement; Section 11 carries the new signatures; Section 16 lists the new reason string; a Rationale paragraph records why; the ERC-165 identifier of `IACDFRegistry` changes from `0x6cb878d2` to `0x843ad5a8` (Section 15 and `interface-ids.json`).
- Tests: two new cases — a round-1 ballot arriving after an appeal opened round 2 is refused while a ballot naming round 2 is accepted, and a future round is refused as well; the same for a submitter's report. 121 tests pass. The registry's runtime grows by 112 bytes to 23,626 (still under EIP-170).

What does not change: `submitSignedBallots` already carries the round inside each signature, so its external signature stays as it was; the adapter and the policy registry are untouched.

On Sepolia: the instance deployed yesterday predates this change. Case A used signed ballots only, whose round binding is unaffected, so the recorded evidence stands as evidence for that profile; the on-chain-tally path of that instance has the old signature. I will redeploy the registry with the next batch of review-driven changes rather than once per fix, and will post the new addresses here.

Thanks again — this is exactly the kind of boundary check the draft needed.
