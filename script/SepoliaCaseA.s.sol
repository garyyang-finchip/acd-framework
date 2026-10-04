// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// Sepolia deployment and Case A for the ACDF reference implementation.
///
/// Four runs, in order (see docs/sepolia-runbook.md):
///   1. DeployCore   deployer: ACDFPolicyRegistry, ACDFRegistry, policy v1, ACDFTaskTenderAdapter;
///                   funds the worker account with gas money.
///   2. MintTask     deployer: mints a task on the live ERC-8414 TaskToken with the adapter as
///                   acceptance authority and funds the reward escrow.
///   3. OpenCase     worker submits the fulfillment; deployer opens the case, relays four EIP-712
///                   signed ballots (one No, three Yes) and settles round 1 -> Provisional.
///   4. Finalize     after the appeal window: finalize -> Final x Decided(Yes); adapter.execute
///                   -> acceptFulfillment, which pays the worker from the task vault.
///
/// State between runs lives in deployments/sepolia.json (written by the scripts; a local
/// rehearsal on chain 31337 writes deployments/local-31337.json instead).
/// Accounts: DEPLOYER_PK (funded), CASE_MNEMONIC (indices 0-4 jurors, 5 worker; jurors never
/// transact, they only sign). ACDF_AUTHORITY is the policy family's update authority.

import {Script, console2} from "forge-std/Script.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";
import {ACDFPolicyRegistry} from "../assets/erc-acdf/contracts/ACDFPolicyRegistry.sol";
import {ACDFRegistry} from "../assets/erc-acdf/contracts/ACDFRegistry.sol";
import {ACDFTaskTenderAdapter} from "../assets/erc-acdf/contracts/adapters/ACDFTaskTenderAdapter.sol";
import {IACDFPolicyRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFPolicyRegistry.sol";
import {IACDFRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFRegistry.sol";
import {ITaskTender8414} from "../assets/erc-acdf/contracts/interfaces/ITaskTender8414.sol";
import {ITaskTender} from "../test/fixtures/task-token/interfaces/ITaskTender.sol";
import {TaskToken} from "../test/fixtures/task-token/TaskToken.sol";

/// The mint entry point of the ERC-8414 reference TaskToken (not part of the tender interface).
interface ITaskTokenMint {
    function mintTask(
        address to,
        address updateAuthority_,
        address acceptanceAuthority_,
        bytes32 tdHash,
        bytes32 taskHash,
        string calldata taskURI_,
        ITaskTender.TenderTerms calldata terms
    ) external returns (uint256 tokenId);
    function nextId() external view returns (uint256);
}

abstract contract CaseABase is Script {
    // ---------------------------------------------------------------- constants of the case
    address constant LIVE_TASK_TOKEN = 0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7; // Sepolia ERC-8414
    uint64  constant MARGIN           = 1800;      // execution margin reserved under the 8414 clocks
    uint64  constant BODY_WINDOW      = 3600;      // juror window per round
    uint32  constant K                = 3;         // 3-of-5
    uint8   constant MAX_APPEALS      = 1;
    uint64  constant APPEAL_WINDOW    = 600;       // ten minutes
    uint64  constant MAX_TOTAL        = 10800;     // >= 2 rounds + 1 appeal window
    uint256 constant REWARD           = 0.001 ether;
    uint64  constant JUDGMENT_WINDOW  = 2 days;    // must cover MAX_TOTAL + MARGIN with room to open
    uint256 constant WORKER_GAS_MONEY = 0.002 ether;
    string  constant TASK_URI         = "https://raw.githubusercontent.com/garyyang-finchip/acd-framework/main/deployments/case-a/task-document.json";
    string  constant RESULT_URI       = "https://raw.githubusercontent.com/garyyang-finchip/acd-framework/main/deployments/case-a/result.json";

    bytes32 constant FAMILY = keccak256("acdf.sepolia.case-a");

    // ---------------------------------------------------------------- accounts
    function deployerKey() internal view returns (uint256) { return vm.envUint("DEPLOYER_PK"); }

    function caseKeys() internal view returns (uint256[5] memory jurorKeys, uint256 workerKey) {
        string memory m = vm.envString("CASE_MNEMONIC");
        for (uint32 i = 0; i < 5; i++) jurorKeys[i] = vm.deriveKey(m, i);
        workerKey = vm.deriveKey(m, 5);
    }

    function jurorAddresses() internal view returns (address[] memory members) {
        (uint256[5] memory keys, ) = caseKeys();
        members = new address[](5);
        for (uint256 i = 0; i < 5; i++) members[i] = vm.addr(keys[i]);
    }

    /// TASK_TOKEN overrides; on Sepolia the default is the live ERC-8414 contract; on a local
    /// chain (31337) address(0) means "deploy the vendored kernel for a rehearsal".
    function taskToken() internal view returns (address) {
        address t = vm.envOr("TASK_TOKEN", address(0));
        if (t != address(0)) return t;
        if (block.chainid == 11155111) return LIVE_TASK_TOKEN;
        require(block.chainid == 31337, "set TASK_TOKEN for this chain");
        return address(0);
    }

    // ---------------------------------------------------------------- the policy of Case A
    function policySpec(address authority) internal view returns (T.PolicySpec memory s) {
        T.BodySpec[] memory bodies = new T.BodySpec[](1);
        bodies[0].kind = T.BodyKind.ROSTER_KOFN;
        bodies[0].acceptance = T.Acceptance.SIGNED_BALLOTS;
        bodies[0].members = jurorAddresses();
        bodies[0].k = K;
        bodies[0].window = BODY_WINDOW;

        T.Node[] memory nodes = new T.Node[](1);
        nodes[0].op = T.Combinator.BODY;
        nodes[0].body = 0;
        nodes[0].children = new uint32[](0);

        s.family = FAMILY;
        s.version = 1;
        s.previous = bytes32(0);
        s.updateAuthority = authority;
        s.bodies = bodies;
        s.nodes = nodes;
        s.maxAppeals = MAX_APPEALS;
        s.appealWindow = APPEAL_WINDOW;
        s.appealable = 1; // Decided results appealable
        s.appealStanding = T.AppealStanding.ANYONE;
        s.maxTotalDuration = MAX_TOTAL;
        s.ackWindow = 0;
        s.allowAdvisory = false;
        s.descriptorHash = fileHash("deployments/case-a/policy-descriptor.json");
    }

    function fileHash(string memory path) internal view returns (bytes32) {
        return keccak256(bytes(vm.readFile(path)));
    }

    // ---------------------------------------------------------------- state file helpers
    /// deployments/sepolia.json on Sepolia; deployments/local-<chainId>.json for rehearsals.
    function stateFile() internal view returns (string memory) {
        if (block.chainid == 11155111) return "deployments/sepolia.json";
        return string(abi.encodePacked("deployments/local-", vm.toString(block.chainid), ".json"));
    }

    function stateAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(stateFile()), key);
    }

    function stateBytes32(string memory key) internal view returns (bytes32) {
        return vm.parseJsonBytes32(vm.readFile(stateFile()), key);
    }

    function stateUint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(stateFile()), key);
    }

    function logResult(IACDFRegistry reg, bytes32 issueId) internal view {
        T.Result memory r = reg.getResult(issueId);
        console2.log("result.state        ", uint8(r.state), "(0 None 1 Filed 2 Deciding 3 Provisional 4 Final 5 Withdrawn)");
        console2.log("result.outcomeType  ", uint8(r.outcomeType), "(0 None 1 Decided 2 NoDecision)");
        console2.log("result.outcomeYes   ", r.outcomeYes);
        console2.log("result.reason       ", uint8(r.reason));
        console2.log("result.decidedAt    ", r.decidedAt);
        console2.log("result.finalAt      ", r.finalAt);
        console2.log("result.roundCount   ", r.roundCount);
        console2.log("result.sourceRound  ", r.sourceRound);
    }
}

/// Run 1: core deployment, policy v1, adapter, worker gas money.
contract DeployCore is CaseABase {
    function run() external {
        address authority = vm.envAddress("ACDF_AUTHORITY");
        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);
        (, uint256 workerKey) = caseKeys();
        address worker = vm.addr(workerKey);
        address task = taskToken();

        vm.startBroadcast(pk);
        if (task == address(0)) {
            // local rehearsal only: deploy the vendored ERC-8414 kernel
            task = address(new TaskToken("Task Token", "TASK"));
        }
        ACDFPolicyRegistry pol = new ACDFPolicyRegistry();
        ACDFRegistry reg = new ACDFRegistry(IACDFPolicyRegistry(address(pol)));
        T.PolicySpec memory spec = policySpec(authority);
        bytes32 policyId = pol.registerPolicy(spec);
        ACDFTaskTenderAdapter adapter =
            new ACDFTaskTenderAdapter(IACDFRegistry(address(reg)), ITaskTender8414(task), policyId, MARGIN);
        payable(worker).transfer(WORKER_GAS_MONEY);
        vm.stopBroadcast();

        require(policyId == pol.policyIdOf(spec), "policyId mismatch");
        require(pol.familyAuthority(FAMILY) == authority, "authority not recorded");

        string memory j = "state";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeAddress(j, "authority", authority);
        vm.serializeAddress(j, "taskToken", task);
        vm.serializeAddress(j, "policyRegistry", address(pol));
        vm.serializeAddress(j, "registry", address(reg));
        vm.serializeAddress(j, "adapter", address(adapter));
        vm.serializeBytes32(j, "policyId", policyId);
        vm.serializeBytes32(j, "family", FAMILY);
        vm.serializeBytes32(j, "descriptorHash", spec.descriptorHash);
        vm.serializeAddress(j, "worker", worker);
        string memory out = vm.serializeAddress(j, "jurors", jurorAddresses());
        vm.writeJson(out, stateFile());

        console2.log("policyRegistry ", address(pol));
        console2.log("registry       ", address(reg));
        console2.log("adapter        ", address(adapter));
        console2.log("policyId       ", vm.toString(policyId));
        console2.log("worker         ", worker);
        console2.log("state written  ", stateFile());
    }
}

/// Run 2: mint the task with the adapter as acceptance authority and fund the escrow.
contract MintTask is CaseABase {
    function run() external {
        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);
        address task = stateAddress(".taskToken");
        address adapter = stateAddress(".adapter");

        bytes32 tdHash = fileHash("deployments/case-a/task-document.json");
        bytes32 taskHash = keccak256(abi.encodePacked("acdf.case-a.task.v1", tdHash));
        ITaskTender.TenderTerms memory terms = ITaskTender.TenderTerms({
            asset: address(0),
            rewardPerCompletion: REWARD,
            maxCompletions: 1,
            submitBy: 0,
            settleBy: 0,
            epochLength: 0,
            maxCompletionsPerEpoch: 0,
            judgmentWindow: JUDGMENT_WINDOW
        });

        vm.startBroadcast(pk);
        uint256 tokenId = ITaskTokenMint(task).mintTask(deployer, deployer, adapter, tdHash, taskHash, TASK_URI, terms);
        ITaskTender(task).fundTask{value: REWARD}(tokenId, REWARD);
        vm.stopBroadcast();

        require(ITaskTender(task).acceptanceAuthorityOf(tokenId) == adapter, "adapter not the judge");
        require(ITaskTender(task).escrowBalanceOf(tokenId) == REWARD, "escrow not funded");

        vm.writeJson(vm.toString(tokenId), stateFile(), ".tokenId");
        vm.writeJson(vm.toString(tdHash), stateFile(), ".tdHash");
        vm.writeJson(vm.toString(taskHash), stateFile(), ".taskHash");
        console2.log("tokenId  ", tokenId);
        console2.log("tdHash   ", vm.toString(tdHash));
        console2.log("taskHash ", vm.toString(taskHash));
    }
}

/// Run 3: worker submits; deployer opens the case, relays signed ballots, settles round 1.
contract OpenCase is CaseABase {
    function run() external {
        uint256 pk = deployerKey();
        (uint256[5] memory jurorKeys, uint256 workerKey) = caseKeys();
        address task = stateAddress(".taskToken");
        ACDFTaskTenderAdapter adapter = ACDFTaskTenderAdapter(stateAddress(".adapter"));
        IACDFRegistry reg = IACDFRegistry(stateAddress(".registry"));
        uint256 tokenId = stateUint(".tokenId");
        bytes32 resultHash = fileHash("deployments/case-a/result.json");

        // the worker delivers
        vm.startBroadcast(workerKey);
        uint256 submissionId = ITaskTender(task).submitFulfillment(tokenId, resultHash, RESULT_URI);
        vm.stopBroadcast();

        // anyone may open; the adapter is the consumer and files the issue itself
        vm.startBroadcast(pk);
        bytes32 issueId = adapter.open(tokenId, submissionId);
        vm.stopBroadcast();

        // ballots: juror 4 blocks first, jurors 1-3 approve; 3-of-5 decides Yes on the third approval
        uint32 round = reg.getResult(issueId).roundCount; // 1
        address[] memory voters = new address[](4);
        bool[] memory approves = new bool[](4);
        bytes[] memory sigs = new bytes[](4);
        uint256[4] memory order = [jurorKeys[3], jurorKeys[0], jurorKeys[1], jurorKeys[2]];
        for (uint256 i = 0; i < 4; i++) {
            voters[i] = vm.addr(order[i]);
            approves[i] = i != 0;
            bytes32 digest = reg.ballotDigest(issueId, round, 0, voters[i], approves[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(order[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }

        vm.startBroadcast(pk);
        reg.submitSignedBallots(issueId, 0, voters, approves, sigs);
        reg.settleRound(issueId);
        vm.stopBroadcast();

        T.Result memory res = reg.getResult(issueId);
        require(res.state == T.ProcedureState.Provisional, "expected Provisional");
        T.RoundState memory rs = reg.getRound(issueId, round);
        require(rs.status == T.NodeStatus.Yes, "expected round Yes");

        vm.writeJson(vm.toString(submissionId), stateFile(), ".submissionId");
        vm.writeJson(vm.toString(resultHash), stateFile(), ".resultHash");
        vm.writeJson(vm.toString(issueId), stateFile(), ".issueId");
        vm.writeJson(vm.toString(rs.appealOpenUntil), stateFile(), ".appealOpenUntil");
        console2.log("submissionId    ", submissionId);
        console2.log("issueId         ", vm.toString(issueId));
        console2.log("round 1 decided ", rs.at);
        console2.log("appealOpenUntil ", rs.appealOpenUntil, "(run Finalize after this unix time)");
        logResult(reg, issueId);
    }
}

/// Run 4: finalize after the appeal window and execute through the real 8414 kernel.
contract Finalize is CaseABase {
    function run() external {
        uint256 pk = deployerKey();
        (, uint256 workerKey) = caseKeys();
        address worker = vm.addr(workerKey);
        address task = stateAddress(".taskToken");
        ACDFTaskTenderAdapter adapter = ACDFTaskTenderAdapter(stateAddress(".adapter"));
        IACDFRegistry reg = IACDFRegistry(stateAddress(".registry"));
        uint256 tokenId = stateUint(".tokenId");
        uint256 submissionId = stateUint(".submissionId");
        bytes32 issueId = stateBytes32(".issueId");
        require(block.timestamp > stateUint(".appealOpenUntil"), "appeal window still open");

        uint256 before = worker.balance;
        vm.startBroadcast(pk);
        reg.finalize(issueId);
        adapter.execute(issueId);
        vm.stopBroadcast();

        T.Result memory res = reg.getResult(issueId);
        require(res.state == T.ProcedureState.Final && res.outcomeType == T.OutcomeType.Decided && res.outcomeYes, "expected Final Decided Yes");
        ITaskTender.Submission memory sub = ITaskTender(task).submissionOf(tokenId, submissionId);
        require(sub.status == ITaskTender.SubmissionStatus.Accepted, "expected Accepted");
        T.Enactment memory en = reg.getEnactment(issueId, address(adapter), adapter.EFFECT_ACCEPT());
        require(en.status == T.EnactmentStatus.Enacted, "expected Enacted");

        // the kernel pushes the reward to the fulfiller; only an unreceivable fulfiller is credited
        uint256 credit = ITaskTender(task).creditOf(tokenId, worker);
        if (credit > 0) {
            vm.startBroadcast(workerKey);
            ITaskTender(task).withdrawCredit(tokenId, worker);
            vm.stopBroadcast();
        } else {
            require(worker.balance == before + REWARD, "expected the reward pushed to the worker");
        }

        vm.writeJson("true", stateFile(), ".enacted");
        console2.log("final           ", "Final x Decided(Yes), enacted through acceptFulfillment");
        console2.log("worker balance  ", worker.balance);
        logResult(reg, issueId);
    }
}
