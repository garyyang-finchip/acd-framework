# Sepolia runbook: deployment and Case A

Four `forge script` runs deploy the reference implementation on Sepolia and take one real
ERC-8414 task-tender submission through the whole procedure: filing by the adapter, EIP-712 signed
ballots relayed by the deployer, settlement, appeal window, finality, and execution through the
live `TaskToken` (`0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7`). Every run simulates first and
broadcasts only if the simulation succeeds, so a failing step costs nothing.

The scripts live in `script/SepoliaCaseA.s.sol`. The same sequence was rehearsed end to end on a
local Anvil chain (chain id 31337) against the vendored kernel before this runbook was written.

## What the run proves

| Step | On-chain fact | Spec clause exercised |
|---|---|---|
| DeployCore | `ACDFPolicyRegistry`, `ACDFRegistry`, `ACDFTaskTenderAdapter` deployed; policy v1 registered, `policyId = keccak256(abi.encode(spec))`, family authority = `ACDF_AUTHORITY` | content-addressed policies, family discipline |
| MintTask | task minted with the adapter as `acceptanceAuthority`, escrow funded with the reward | consumer commitment made by the relying contract's owner |
| OpenCase | worker submits; `adapter.open` files a CONSUMER_FILED Binding issue bound to the exact submission and to `min(judgment clock, settleBy) - margin`; four signed ballots (one No, three Yes) relayed in one transaction; `settleRound` -> Provisional with a 10-minute appeal window | signed-ballot profile, K-of-N approval rule, decision instant = third approval, appeal window from the decision instant |
| Finalize | `finalize` -> Final x Decided(Yes), `sourceRound = roundCount = 1`; `adapter.execute` -> `acceptFulfillment`; the kernel pays the worker; enactment recorded as Enacted | Final is terminal; kernel never moves assets, the consumer enforces its own effect |

## Prerequisites

- Foundry (forge 1.x), or the `ghcr.io/foundry-rs/foundry` Docker image. Clone the repository and fetch
  forge-std once: `git clone --depth 1 --branch v1.17.0 https://github.com/foundry-rs/forge-std lib/forge-std`.
- A Sepolia RPC URL (`SEPOLIA_RPC_URL`).
- A funded deployer key (`DEPLOYER_PK`). The whole sequence used about 11.3M gas in rehearsal
  (ACDFRegistry alone 5.14M); at 1-2 gwei that is 0.012-0.025 ETH, plus 0.001 ETH reward escrow
  and 0.002 ETH gas money sent to the worker account.
- A fresh mnemonic for the case accounts (`CASE_MNEMONIC`): indices 0-4 are the five jurors (they
  only sign, never transact), index 5 is the worker (funded by DeployCore). Generate one with
  `cast wallet new-mnemonic`. Keep it: Finalize needs it again, and the juror addresses are part
  of the registered policy.
- The address that will hold the policy family's update authority (`ACDF_AUTHORITY`). It is
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

Writes `deployments/sepolia.json` (addresses, `policyId`, family, descriptor hash, jurors, worker).
Add `--verify --etherscan-api-key $ETHERSCAN_API_KEY` to verify the three contracts' source on
Etherscan in the same run (optional; it can also be done afterwards with `forge verify-contract`).

## Run 2: mint and fund the task

```bash
forge script script/SepoliaCaseA.s.sol:MintTask --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

Mints the task on the live TaskToken with `tdHash = keccak256(deployments/case-a/task-document.json)`,
`taskHash = keccak256("acdf.case-a.task.v1" || tdHash)`, a 2-day judgment window, one completion at
0.001 ETH, and funds the escrow. Records `tokenId`, `tdHash`, `taskHash`.

## Run 3: submission, case, ballots, settlement

```bash
forge script script/SepoliaCaseA.s.sol:OpenCase --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

The worker submits `resultHash = keccak256(deployments/case-a/result.json)`; the deployer opens the
case, relays the four signed ballots and settles round 1. The log prints `appealOpenUntil` (unix
time). Records `submissionId`, `resultHash`, `issueId`, `appealOpenUntil`.

## Run 4: finality and execution (after the appeal window)

Wait until the printed `appealOpenUntil` has passed (ten minutes after the third approval), then:

```bash
forge script script/SepoliaCaseA.s.sol:Finalize --rpc-url $SEPOLIA_RPC_URL --broadcast -vv
```

The script refuses to run while the window is open. It finalizes, executes through the adapter and
checks on chain that the submission is Accepted, the enactment is Enacted and the worker received
the reward.

## Result of the run on 2026-10-04

All four runs succeeded; the record is in `deployments/sepolia.json` and `deployments/sepolia-case-a.json`.
One detail worth knowing: the `appealOpenUntil` printed by OpenCase comes from the simulation and can
be a few blocks earlier than the on-chain value; Finalize checks the state-file value, and the
registry itself rejects an early `finalize` during simulation, so simply wait a minute longer.

## What to send back for the evidence record

- `deployments/sepolia.json`
- every file in `broadcast/SepoliaCaseA.s.sol/11155111/` (transaction hashes, receipts, gas)
- the console output of the four runs (optional)

These are distilled into `deployments/sepolia.json` + `deployments/sepolia-case-a.json`, the README
addresses and the Magicians follow-up. Keys never leave the machine that runs the scripts: the
scripts read them from the environment and Foundry stores only transaction records.

## Parameters of the case (fixed in the script)

- policy family `keccak256("acdf.sepolia.case-a")`, version 1
- body 0: ROSTER_KOFN, SIGNED_BALLOTS, five jurors, k = 3, window 3600 s; single BODY node
- maxAppeals 1, appealWindow 600 s, appealable = Decided results, appealStanding ANYONE,
  maxTotalDuration 10800 s, ackWindow 0, allowAdvisory false
- descriptorHash = keccak256 of `deployments/case-a/policy-descriptor.json`
- adapter margin 1800 s; task judgment window 2 days; settleBy 0; reward 0.001 ETH, one completion
- ballots in order: juror 4 No, juror 1 Yes, juror 2 Yes, juror 3 Yes (the body decides Yes on the
  third approval; the dissent is on record)
