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

## Run 1: core deployment

```bash
forge script script/SepoliaCaseA.s.sol:DeployCore --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

Writes `deployments/sepolia.json` (addresses, both `policyId`s, families, descriptor hashes, jurors, worker).

## Run 2: mint and fund both tasks

```bash
forge script script/SepoliaCaseA.s.sol:MintTasks --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

`tdHash = keccak256(deployments/case-a/task-document.json)` resp. `case-a2/`, `taskHash = keccak256("acdf.case-a.task.v1" || tdHash)` resp. `"acdf.case-a2.task.v1"`, 2-day judgment window, one completion at 0.001 ETH each.

## Run 3: submissions, cases, ballots, settlements, appeal

```bash
forge script script/SepoliaCaseA.s.sol:OpenCases --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

Nine transactions. The log prints two instants: Case A's `appealOpenUntil` (ten minutes after the third approval) and the close of Case A2's round 2 (fifteen minutes after the appeal). Both are simulation estimates and can be a few blocks early; wait a minute beyond the later one.

## Run 4: finality (after both windows)

```bash
forge script script/SepoliaCaseA.s.sol:Finalize --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

Three transactions: `finalize(A)`, `execute(A)`, `settleRound(A2)`. The script checks every assertion of the table above and refuses to run while a window is open.

## What to send back for the evidence record

- `deployments/sepolia.json`
- every file in `broadcast/SepoliaCaseA.s.sol/11155111/` (transaction hashes, receipts, gas)
- the console output of the four runs (optional)

These are distilled into `deployments/sepolia.json` + `deployments/sepolia-cases.json`, the README
addresses and the Magicians follow-up. Keys never leave the machine that runs the scripts: the
scripts read them from the environment and Foundry stores only transaction records.

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
