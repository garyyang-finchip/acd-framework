# Magicians reply: body roles in composition; default claim before execute

Reply to Revinand (#10) and ted0x (#9) in topic 29850 (draft; post as one reply). Companion PR comment at the end.

---

@Revinand Not intentional — thank you, and well spotted. Validation enforced that every *node* is referenced exactly once and never looked at which *body* a `BODY` leaf names, so your `KOFM` tree lets one decision fill two threshold slots and your `VETO` tree can never form `Yes` (body 0 approving vetoes, body 0 refusing blocks the `ALL`). Composition in this proposal combines the decisions of distinct bodies by logic — that was the whole argument against pooling ballots — so I have closed it in validation rather than documenting reuse. Section 3 now requires, and `ACDFPolicyRegistry` now checks:

- a body index appears as a `BODY` leaf at most once per policy (`ACDF: body reused`);
- a body named as any `VETO` node's `vetoBody` appears as a `BODY` leaf nowhere in the policy (`ACDF: veto body votes`). This is one step stricter than the subtree-scoped version you proposed: a veto body that votes *outside* the subtree it guards, e.g. `ALL(VETO(0 → BODY(1)), BODY(0))`, is the same dead tree — approve vetoes, refuse blocks the `ALL` — so the roles are simply separated. Your legitimate case stays allowed and is now stated in Section 8: one screening body may guard several separate targets through several `VETO` nodes; it decides once per round and each guard reads that decision;
- every declared body is referenced at least once, as a leaf or as a veto body (`ACDF: body unused`). An idle body would still open ballots and stretch the round to its window.

Tests cover both of your trees, the outside-the-guard variant, an idle body, and the shared-veto policy (registered, cleared by the screening body, both chambers approve, root `Yes`). `PolicySpec` and both interfaces are unchanged, so every `policyId` and both ERC-165 ids stay as they were; only the policy registry's validation changed (10,201 bytes now). The policy registry on Sepolia predates this and would still accept such a tree; the two deployed policies have a single body each, so nothing there is affected, and it will be redeployed with the next batch of changes rather than for this alone.

@ted0x Thank you for the ordering test — it is in the adapter suite as `test_default_claim_before_execute_pays_once_but_enactment_is_failed`, credited to you in the test record, and passes unchanged against the current tree (135 tests now). Section 14 says what you asked for: an enactment record describes the adapter's attempt, not the fate of the obligation; when the relying contract's own default (here `claimUnjudged` after the judgment window) settled first, a later `execute` is recorded as `Failed` while the submission is already accepted and paid, repeating it changes nothing and pays nothing, and an integration that displays a payment status reads it, and its source, from the relying contract's records — which Section 10 already makes authoritative for execution state. Your test and the late `execute` of our first Sepolia attempt (#8) are the two sides of the same boundary: the kernel decides what a late or redundant enactment is worth, the registry only records what the adapter did.

Both changes are on PR #2046 together.

---

## PR #2046 comment (post after the two files are on the branch)

@jochem-brouwer one more change landed on this branch while your re-review is pending, from the Magicians thread (topic 29850, #9 and #10): policy validation now rejects a body that appears as more than one `BODY` leaf, a body used as a `vetoBody` that also appears as a `BODY` leaf, and a declared body that the tree never references (Section 3, bullet on body roles; one sentence in Section 8 allowing one veto body to guard several targets; three new reason strings in Section 16; one Rationale paragraph). `PolicySpec` and both interfaces are unchanged, so every `policyId` and ERC-165 id stays as it was; in the assets only `ACDFPolicyRegistry.sol` changed. Section 14 (informative) also gained a paragraph on reading a `Failed` enactment when the relying contract's default path settled first. Files touched: `ERCS/erc-8436.md`, `assets/erc-8436/contracts/ACDFPolicyRegistry.sol`.
