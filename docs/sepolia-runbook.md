# Sepolia runbook: deployment, Case A and Case A2 (revision 2)

Four `forge script` runs deploy the revision-2 reference implementation on Sepolia and take two real
ERC-8414 submissions through the procedure against the live `TaskToken`
(`0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`). Case A (policy family `acdf.sepolia.case-a`,
PRESERVE_UNLESS_OVERTURNED) ends in Final x Decided(Yes) and pays the worker through
`acceptFulfillment`. Case A2 (family `acdf.sepolia.case-a2`, REQUIRE_FRESH_DECISION) decides Yes in
round 1, is appealed, and its appeal round ends without ballots: the issue ends in NoDecision, the
adapter refuses to execute, and the tender's own judgment clock governs. Every run simulates first
and broadcasts only if the simulation succeeds.

The scripts live in `script/SepoliaCaseA.s.sol` and were rehearsed end to end on a local Anvil chain
against the vendored kernel. The v0.2 run of 2026-10-04 is archived under `deployments/archive/`.

## What the runs prove

| Step | On-chain fact | Spec clause exercised |
|---|---|---|
| DeployCore | registries deployed; policies A (PRESERVE) and A2 (REQUIRE_FRESH) registered with their `policyId = keccak256(abi.encode(spec))`, family authority = `ACDF_AUTHORITY`; one adapter per policy | content-addressed policies incl. `appealMode`, family discipline |
| MintTasks | two tasks minted with their adapters as `acceptanceAuthority`, escrows funded | consumer commitment by the relying contract's owner |
| OpenCases | worker submits on both; each adapter files a CONSUMER_FILED Binding issue with `obligationId = keccak256(task, tokenId, submissionId)`; A: one No + three Yes, settle -> Provisional; A2: three Yes, settle -> Provisional, `appeal` -> round 2 | obligation scope, signed-ballot profile, K-of-N approval rule, appeal window from the decision instant, appeal standing |
| Finalize | A: `finalize` -> Final x Decided(Yes), `adoptedFromEarlierRound = false`, `execute` -> `acceptFulfillment` pays; A2: round 2 settles NoDecision(QUORUM_NOT_MET) -> Final x NoDecision under REQUIRE_FRESH_DECISION, round 1's Yes stays on record but vacated, `execute` refused, submission still Pending | adoption rule by mode, Final is terminal, kernel never moves assets, NoDecision disposition |

## Prerequisites

- Foundry (forge 1.x), or the `ghcr.io/foundry-rs/foundry` Docker image. Clone the repository and fetch
  forge-std once: `git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std lib/forge-std`.
- A Sepolia RPC URL (`SEPOLIA_RPC_URL`).
- A funded deployer key (`DEPLOYER_PK`). The whole sequence used about 15.3M gas in rehearsal
  (ACDFRegistry alone 5.3M); at 1-2 gwei that is 0.017-0.034 ETH, plus 0.002 ETH of reward escrow
  and 0.003 ETH gas money sent to the worker account.
- A fresh mnemonic for the case accounts (`CASE_MNEMONIC`): indices 0-4 are the five jurors (they
  only sign, never transact), index 5 is the worker (funded by DeployCore). Generate one with
  `cast wallet new-mnemonic`. Keep it: Finalize needs it again, and the juror addresses are part
  of the registered policy.
- The address that will hold both policy families' update authority (`ACDF_AUTHORITY`). It is
  written into the hashed `PolicySpec`; there is no transfer function, so decide it before run 1.

```bash
export SEPOLIA_RPC_URL=https://...
export DEPLOYER_PK=0x...
export CASE_MNEMONIC="twelve words ..."
export ACDF_AUTHORITY=0x...
```

## Gas estimation on Sepolia

Sepolia's execution costs no longer match the EVM model inside the Foundry build used here (observed
2026-10-09: contract creation and storage-heavy calls cost five to seven times what the local
simulation computes, the block gas limit is 200M and the base fee is a few wei). Transactions sized
by the local simulation run out of gas on chain while the simulation passes. Let the node size them:
pass `--skip-simulation --gas-estimate-multiplier 150` to every broadcast, so Foundry asks the RPC
for `eth_estimateGas` instead of using its own model. Unused gas is refunded, so this costs nothing.

## Run 1: core deployment

```bash
forge script script/SepoliaCaseA.s.sol:DeployCore --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
```

Writes `deployments/sepolia.json` (addresses, both `policyId`s, families, descriptor hashes, jurors, worker).

## Run 2: mint and fund both tasks

```bash
forge script script/SepoliaCaseA.s.sol:MintTasks --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
```

`tdHash = keccak256(deployments/case-a/task-document.json)` resp. `case-a2/`, `taskHash = keccak256("acdf.case-a.task.v1" || tdHash)` resp. `"acdf.case-a2.task.v1"`, 2-day judgment window, one completion at 0.001 ETH each.

## Run 3: submissions, cases, ballots, settlements, appeal

```bash
forge script script/SepoliaCaseA.s.sol:OpenCases --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
```

Nine transactions. The log prints two instants: Case A's `appealOpenUntil` (ten minutes after the third approval) and the close of Case A2's round 2 (fifteen minutes after the appeal). Both are simulation estimates and can be a few blocks early; wait a minute beyond the later one.

## Run 4: finality (after both windows)

```bash
forge script script/SepoliaCaseA.s.sol:Finalize --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
```

Three transactions: `finalize(A)`, `execute(A)`, `settleRound(A2)`. The script checks every assertion of the table above and refuses to run while a window is open.

The `finalAt` values the console prints come from the local execution of the script against the forked block, so both cases show the same instant; the on-chain values are the timestamps of the blocks that mined `finalize(A)` and `settleRound(A2)` (read them back with `getResult`).

## If Finalize is missed: closing a first attempt and rerunning

If run 4 was not executed before the kernel's judgment window closed (two days after the
submissions), the registry side still finalizes, but the case record would no longer show the
intended path. Two extra runs handle this:

```bash
forge script script/SepoliaCaseA.s.sol:CloseFirstAttempt --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
forge script script/SepoliaCaseA.s.sol:RedeployAdapters  --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
```

`CloseFirstAttempt` reads the first attempt's facts from `deployments/sepolia-first-attempt-input.json` on Sepolia, finalizes Case A and executes it late (the kernel bounds `acceptFulfillment` by
`settleBy` only, so with `settleBy = 0` the late accept still pays the worker; had it been refused,
the enactment would be recorded as Failed and the kernel default `claimUnjudged` would pay instead),
settles Case A2 as NoDecision and pays its submission through `claimUnjudged`. The record goes to
`deployments/sepolia-first-attempt.json`. `RedeployAdapters` deploys the two adapters again from the
current assets (registries and policies stay) and points the state file at them; then runs 2, 3 and
4 are repeated for a clean record.

## What to send back for the evidence record

- `deployments/sepolia.json`
- every file in `broadcast/SepoliaCaseA.s.sol/11155111/` (transaction hashes, receipts, gas)
- the console output of the four runs (optional)

These are distilled into `deployments/sepolia-cases.json`, the README addresses and the Magicians
follow-up. Keys never leave the machine that runs the scripts: the scripts read them from the
environment and Foundry stores only transaction records.

## Record of the revision-2 run (2026-10-05 / 2026-10-09)

| Run | Day (UTC) | Blocks | Result |
|---|---|---|---|
| DeployCore | 2026-10-05 | 11851558 | `ACDFPolicyRegistry` `0x7e870B29C903e71517676d52FCCD20Ef96477A73`, `ACDFRegistry` `0xbA03B451B421b5041d7bE7b5Fd7DbcF3B6Aa1354`, policies A `0xb231869b...0401` and A2 `0x3e431bbb...d063`, first-attempt adapters |
| MintTasks, OpenCases (first attempt) | 2026-10-05 | 11851571-11851580 | tasks #9/#10; issues `0xf64cde86...1646` / `0xcdb8e61a...fdd0`; A Provisional(Yes), A2 Provisional(Yes) then appealed |
| CloseFirstAttempt | 2026-10-09 | 11874938, 11875177-78 | A Final x Decided(Yes), late `execute` accepted by the kernel (`settleBy = 0`), paid; A2 Final x NoDecision, `claimUnjudged(10, 1)` paid |
| RedeployAdapters | 2026-10-09 | 11875241-42 | adapters `0x09c3550cCAfc2E73B1f0edA3ECA2f5247bB24Da7` (A) and `0x078271c288141660753b1BfB67A3cfc2F06c8AC2` (A2) from the current assets |
| MintTasks | 2026-10-09 | 11875284-87 | tasks #13/#14, 0.001 ETH each |
| OpenCases | 2026-10-09 | 11875438-52 | issues `0xf2e88a4e...1dc8` / `0x2ff1ec2f...4cdc`; A: No + 3 Yes, settle (decidedAt 1791526056); A2: 3 Yes, settle, `appeal` at 1791526104 |
| Finalize | 2026-10-09 | 11875531-33 | A: Final x Decided(Yes), finalAt 1791527052, `acceptFulfillment(13, 1)` paid; A2: round 2 NoDecision(QUORUM_NOT_MET), Final, decidedAt 1791527004, finalAt 1791527076, `execute` refused, submission Pending |

Every transaction hash, gas figure and the decoded `getResult` of both issues are in
`deployments/sepolia-cases.json`. The deployed runtime of all four contracts was compared with a
fresh build of the assets (SHA-256 over the code with the immutable slots zeroed) and matches.
Superseded on-chain artifacts (the v0.2 contracts, one accidental v0.2 duplicate, tasks #11/#12
minted against adapters whose creation had run out of gas) are listed in the same file.

## Parameters of the cases (fixed in the script)

Common: five jurors (SIGNED_BALLOTS, k = 3, single BODY node), maxAppeals 1, appealWindow 600 s,
appealable = Decided results, appealStanding ANYONE, ackWindow 0, allowAdvisory false; adapter
margin 1800 s; task judgment window 2 days; settleBy 0; reward 0.001 ETH, one completion.

- Case A: family `keccak256("acdf.sepolia.case-a")`, body window 3600 s, maxTotalDuration 10800 s,
  appealMode PRESERVE_UNLESS_OVERTURNED, descriptorHash = keccak256 of
  `deployments/case-a/policy-descriptor.json`; ballots in order juror 4 No, jurors 1-3 Yes.
- Case A2: family `keccak256("acdf.sepolia.case-a2")`, body window 900 s, maxTotalDuration 3600 s,
  appealMode REQUIRE_FRESH_DECISION, descriptorHash = keccak256 of
  `deployments/case-a2/policy-descriptor.json`; ballots jurors 1-3 Yes in round 1, none in round 2;
  the appeal is filed by the deployer account (standing ANYONE).

## Revision 3: body-role registries, Case B (composition, veto, on-chain ballots) and Case C (reject)

`script/SepoliaCaseBC.s.sol` redeploys the registries (the policy registry now enforces the body-role
rules of Section 3) and runs two more cases against the same live `TaskToken`, with the same accounts
and the same flags. State lives in `deployments/sepolia-r3.json`; the revision-2 contracts and record
stay as they are.

| Run | Proves |
|---|---|
| DeployCoreR3 | registries with body-role validation (a dead tree — the veto body voting as a leaf — is offered locally and refused with `ACDF: veto body votes`); policy B = `VETO(screening) -> ALL(technical chamber, economic chamber)`, screening 1-of-2 signed ballots with a 15-minute window under `REQUIRE_CLEARANCE`, chambers 2-of-3 on-chain ballots; policy C = 3-of-5 signed ballots; one adapter per policy; gas money for the worker and the four jurors who transact |
| MintTasksR3 | tasks B and C with their adapters as `acceptanceAuthority`, escrows funded |
| OpenCasesR3 | worker submits on both; both cases opened; screening clears explicitly (two signed No ballots); jurors 1 and 2 cast on-chain `castBallot(issue, round, body 1, Yes)`, jurors 4 and 5 for body 2; `settleRound` -> Provisional(Yes) before the veto window closed (explicit clearance lets the target pass early); C: three signed No ballots, `settleRound` -> Provisional(No) |
| FinalizeR3 | B: `finalize` -> Final x Decided(Yes), `execute` -> `acceptFulfillment` pays; C: `finalize` -> Final x Decided(No), `execute` -> `rejectFulfillment`: submission Rejected, `Enacted` under `task-tender.rejectFulfillment`, `pendingOf` 0 (slot released), escrow unchanged, nothing credited to the worker |

```bash
forge script script/SepoliaCaseBC.s.sol:DeployCoreR3 --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
forge script script/SepoliaCaseBC.s.sol:MintTasksR3  --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
forge script script/SepoliaCaseBC.s.sol:OpenCasesR3  --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
# wait for both appealOpenUntil instants printed by OpenCasesR3 (about ten minutes), plus a minute
forge script script/SepoliaCaseBC.s.sol:FinalizeR3   --rpc-url $SEPOLIA_RPC_URL --broadcast --skip-simulation --gas-estimate-multiplier 150 -vv
```

Budget: the deployer needs about 0.015 ETH at the repriced fee level of October 2026 (0.002 ETH of
escrows, 0.003 ETH to the worker, 4 x 0.002 ETH to the jurors, the rest gas); at 1 gwei the four
contract creations alone would need roughly 0.05 ETH — check `cast basefee` before run 1 and top up
from a faucet if the base fee has gone back up. Rehearsed twice end to end on a local Anvil chain
against the vendored kernel, with the clock advanced between runs 3 and 4.

Parameters of the cases: common appeals (maxAppeals 1, appealWindow 600 s, appealable = Decided,
standing ANYONE, PRESERVE_UNLESS_OVERTURNED), adapter margin 1800 s, task judgment window 2 days,
settleBy 0, reward 0.001 ETH, one completion. Case B: family `keccak256("acdf.sepolia.case-b")`,
bodies screening = jurors 4-5 (k 1, 900 s, SIGNED_BALLOTS), technical = jurors 1-3 (k 2, 3600 s,
ON_CHAIN_TALLY), economic = jurors 3-5 (k 2, 3600 s, ON_CHAIN_TALLY); nodes VETO(0 -> 1,
REQUIRE_CLEARANCE), ALL(2, 3), BODY(1), BODY(2); maxTotalDuration 10800 s; descriptor
`deployments/case-b/policy-descriptor.json`. Case C: family `keccak256("acdf.sepolia.case-c")`, the
Case A body (jurors 1-5, k 3, 3600 s, SIGNED_BALLOTS), ballots jurors 1-3 No; descriptor
`deployments/case-c/policy-descriptor.json`; the submitted result deliberately answers a different
question (`deployments/case-c/result.json`).
