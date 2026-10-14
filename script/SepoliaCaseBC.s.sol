// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// Sepolia deployment, revision 3: the registries with body-role validation, and two more live cases
/// against the ERC-8414 reference TaskToken, covering what revisions 1-2 did not reach on chain:
/// composition with a veto, on-chain ballots, and the reject path.
///
/// Four runs, in order (see docs/sepolia-runbook.md):
///   1. DeployCoreR3   deployer: ACDFPolicyRegistry (with the body-role rules), ACDFRegistry, policy B
///                     (VETO(screening) over ALL(technical chamber, economic chamber); chambers vote on
///                     chain), policy C (single 3-of-5 body, signed ballots), one adapter per policy;
///                     gas money for the worker and the four jurors who transact. A dead tree
///                     (veto body voting as a leaf) is offered to the new registry locally and refused.
///   2. MintTasksR3    deployer: mints task B (adapter B as acceptance authority) and task C (adapter C),
///                     funds both escrows.
///   3. OpenCasesR3    worker submits on both tasks; deployer opens both cases; screening body clears
///                     explicitly (two signed No ballots); technical chamber (jurors 1, 2) and economic
///                     chamber (jurors 4, 5) cast on-chain ballots; settle -> B Provisional(Yes) before
///                     the veto window closes. C: three signed No ballots, settle -> Provisional(No).
///   4. FinalizeR3     after the appeal windows: B finalize -> Final x Decided(Yes), execute ->
///                     acceptFulfillment pays the worker. C finalize -> Final x Decided(No), execute ->
///                     rejectFulfillment: the submission is Rejected, the reserved slot is released,
///                     the escrow stays with the task, the worker is not paid.
///
/// State between runs lives in deployments/sepolia-r3.json (deployments/local-r3-<chainId>.json on
/// a local rehearsal). Accounts as in SepoliaCaseA.s.sol: DEPLOYER_PK, CASE_MNEMONIC (indices 0-4
/// jurors, 5 worker), ACDF_AUTHORITY.

import {console2} from "forge-std/Script.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";
import {ACDFPolicyRegistry} from "../assets/erc-acdf/contracts/ACDFPolicyRegistry.sol";
import {ACDFRegistry} from "../assets/erc-acdf/contracts/ACDFRegistry.sol";
import {ACDFTaskTenderAdapter} from "../assets/erc-acdf/contracts/adapters/ACDFTaskTenderAdapter.sol";
import {IACDFPolicyRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFPolicyRegistry.sol";
import {IACDFRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFRegistry.sol";
import {ITaskTenderKernel} from "../assets/erc-acdf/contracts/interfaces/ITaskTenderKernel.sol";
import {ITaskTender} from "../test/fixtures/task-token/interfaces/ITaskTender.sol";
import {TaskToken} from "../test/fixtures/task-token/TaskToken.sol";
import {CaseBase, ITaskTokenMint} from "./SepoliaCaseA.s.sol";

abstract contract CaseBaseR3 is CaseBase {
    uint256 constant JUROR_GAS_MONEY = 0.002 ether;

    // Case B: screening veto (signed, 1-of-2, 15-minute window, REQUIRE_CLEARANCE) over ALL(tech, econ)
    // (on-chain, 2-of-3 each, 1-hour window); one appeal, 10-minute appeal window, PRESERVE.
    bytes32 constant FAMILY_B  = keccak256("acdf.sepolia.case-b");
    uint64  constant WINDOW_B_SCREEN = 900;
    uint64  constant WINDOW_B  = 3600;
    uint64  constant APPEAL_B  = 600;
    uint64  constant TOTAL_B   = 10800;
    // Case C: as Case A (3-of-5, signed ballots, 1-hour window) with the ballots going the other way.
    bytes32 constant FAMILY_C  = keccak256("acdf.sepolia.case-c");
    uint64  constant WINDOW_C  = 3600;
    uint64  constant APPEAL_C  = 600;
    uint64  constant TOTAL_C   = 10800;

    function stateFile() internal view override returns (string memory) {
        if (block.chainid == 11155111) return "deployments/sepolia-r3.json";
        return string(abi.encodePacked("deployments/local-r3-", vm.toString(block.chainid), ".json"));
    }

    function roster(uint256 a, uint256 b) internal view returns (address[] memory m) {
        address[] memory j = jurorAddresses();
        m = new address[](2); m[0] = j[a]; m[1] = j[b];
    }

    function roster(uint256 a, uint256 b, uint256 c) internal view returns (address[] memory m) {
        address[] memory j = jurorAddresses();
        m = new address[](3); m[0] = j[a]; m[1] = j[b]; m[2] = j[c];
    }

    function body(T.Acceptance acc, address[] memory members, uint32 k, uint64 window) internal pure returns (T.BodySpec memory b) {
        b.kind = T.BodyKind.ROSTER_KOFN;
        b.acceptance = acc;
        b.members = members;
        b.k = k;
        b.window = window;
    }

    function bodyNode(uint32 bodyIndex) internal pure returns (T.Node memory n) {
        n.op = T.Combinator.BODY;
        n.body = bodyIndex;
        n.children = new uint32[](0);
    }

    function policySpecB(address authority) internal view returns (T.PolicySpec memory s) {
        T.BodySpec[] memory bodies = new T.BodySpec[](3);
        bodies[0] = body(T.Acceptance.SIGNED_BALLOTS, roster(3, 4), 1, WINDOW_B_SCREEN); // screening: jurors 4, 5
        bodies[1] = body(T.Acceptance.ON_CHAIN_TALLY, roster(0, 1, 2), 2, WINDOW_B);     // technical chamber: jurors 1, 2, 3
        bodies[2] = body(T.Acceptance.ON_CHAIN_TALLY, roster(2, 3, 4), 2, WINDOW_B);     // economic chamber: jurors 3, 4, 5
        T.Node[] memory nodes = new T.Node[](4);
        nodes[0].op = T.Combinator.VETO; nodes[0].target = 1; nodes[0].vetoBody = 0;
        nodes[0].silence = T.VetoSilence.REQUIRE_CLEARANCE; nodes[0].children = new uint32[](0);
        nodes[1].op = T.Combinator.ALL; nodes[1].children = new uint32[](2);
        nodes[1].children[0] = 2; nodes[1].children[1] = 3;
        nodes[2] = bodyNode(1);
        nodes[3] = bodyNode(2);
        s.family = FAMILY_B;
        s.version = 1;
        s.updateAuthority = authority;
        s.bodies = bodies;
        s.nodes = nodes;
        s.maxAppeals = 1;
        s.appealWindow = APPEAL_B;
        s.appealable = 1;
        s.appealStanding = T.AppealStanding.ANYONE;
        s.appealMode = T.AppealMode.PRESERVE_UNLESS_OVERTURNED;
        s.maxTotalDuration = TOTAL_B;
        s.ackWindow = 0;
        s.allowAdvisory = false;
        s.descriptorHash = fileHash("deployments/case-b/policy-descriptor.json");
    }

    /// Revinand's second tree (Magicians topic 29850, #10): the veto body also votes inside the subtree
    /// it guards. Used only to show the new registry refuses it.
    function deadTree(address authority) internal view returns (T.PolicySpec memory s) {
        s = policySpecB(authority);
        s.family = keccak256("acdf.sepolia.dead-tree");
        s.nodes[2] = bodyNode(0); // BODY(0) under the VETO guarded by body 0
        s.descriptorHash = keccak256("dead tree");
    }
}

/// Run 1: core deployment (revision 3), policies B and C, two adapters, gas money.
contract DeployCoreR3 is CaseBaseR3 {
    function run() external {
        address authority = vm.envAddress("ACDF_AUTHORITY");
        uint256 pk = deployerKey();
        (uint256[5] memory jk, uint256 workerKey) = caseKeys();
        address worker = vm.addr(workerKey);
        address task = taskToken();

        vm.startBroadcast(pk);
        if (task == address(0)) task = address(new TaskToken("Task Token", "TASK")); // local rehearsal only
        ACDFPolicyRegistry pol = new ACDFPolicyRegistry();
        ACDFRegistry reg = new ACDFRegistry(IACDFPolicyRegistry(address(pol)));
        T.PolicySpec memory specB = policySpecB(authority);
        T.PolicySpec memory specC = policySpec(authority, FAMILY_C, WINDOW_C, APPEAL_C, TOTAL_C,
            T.AppealMode.PRESERVE_UNLESS_OVERTURNED, "deployments/case-c/policy-descriptor.json");
        bytes32 policyB = pol.registerPolicy(specB);
        bytes32 policyC = pol.registerPolicy(specC);
        ACDFTaskTenderAdapter adapterB = new ACDFTaskTenderAdapter(IACDFRegistry(address(reg)), ITaskTenderKernel(task), policyB, MARGIN);
        ACDFTaskTenderAdapter adapterC = new ACDFTaskTenderAdapter(IACDFRegistry(address(reg)), ITaskTenderKernel(task), policyC, MARGIN);
        payable(worker).transfer(WORKER_GAS_MONEY);
        payable(vm.addr(jk[0])).transfer(JUROR_GAS_MONEY); // the four jurors who cast on-chain ballots
        payable(vm.addr(jk[1])).transfer(JUROR_GAS_MONEY);
        payable(vm.addr(jk[3])).transfer(JUROR_GAS_MONEY);
        payable(vm.addr(jk[4])).transfer(JUROR_GAS_MONEY);
        vm.stopBroadcast();

        require(policyB == pol.policyIdOf(specB) && policyC == pol.policyIdOf(specC), "policyId mismatch");
        require(pol.familyAuthority(FAMILY_B) == authority && pol.familyAuthority(FAMILY_C) == authority, "authority");

        // Local check only (not a transaction): the body-role rules refuse the dead tree.
        try pol.registerPolicy(deadTree(authority)) {
            revert("dead tree accepted");
        } catch Error(string memory reason) {
            require(keccak256(bytes(reason)) == keccak256("ACDF: veto body votes"), reason);
            console2.log("dead tree refused by the new registry:", reason);
        }

        string memory j = "state";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", vm.addr(pk));
        vm.serializeAddress(j, "authority", authority);
        vm.serializeAddress(j, "taskToken", task);
        vm.serializeAddress(j, "policyRegistry", address(pol));
        vm.serializeAddress(j, "registry", address(reg));
        vm.serializeAddress(j, "adapterB", address(adapterB));
        vm.serializeAddress(j, "adapterC", address(adapterC));
        vm.serializeBytes32(j, "policyB", policyB);
        vm.serializeBytes32(j, "policyC", policyC);
        vm.serializeBytes32(j, "descriptorHashB", specB.descriptorHash);
        vm.serializeBytes32(j, "descriptorHashC", specC.descriptorHash);
        vm.serializeAddress(j, "worker", worker);
        string memory out = vm.serializeAddress(j, "jurors", jurorAddresses());
        vm.writeJson(out, stateFile());

        console2.log("policyRegistry", address(pol));
        console2.log("registry      ", address(reg));
        console2.log("adapterB      ", address(adapterB));
        console2.log("adapterC      ", address(adapterC));
        console2.log("policyB       ", vm.toString(policyB));
        console2.log("policyC       ", vm.toString(policyC));
        console2.log("worker        ", worker);
    }
}

/// Run 2: mint both tasks with their adapters as acceptance authority and fund the escrows.
contract MintTasksR3 is CaseBaseR3 {
    function run() external {
        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);
        address task = stateAddress(".taskToken");
        bytes32 tdB = fileHash("deployments/case-b/task-document.json");
        bytes32 tdC = fileHash("deployments/case-c/task-document.json");
        bytes32 thB = keccak256(abi.encodePacked("acdf.case-b.task.v1", tdB));
        bytes32 thC = keccak256(abi.encodePacked("acdf.case-c.task.v1", tdC));

        vm.startBroadcast(pk);
        uint256 tokenB = ITaskTokenMint(task).mintTask(deployer, deployer, stateAddress(".adapterB"), tdB, thB,
            string.concat(RAW, "case-b/task-document.json"), terms());
        ITaskTender(task).fundTask{value: REWARD}(tokenB, REWARD);
        uint256 tokenC = ITaskTokenMint(task).mintTask(deployer, deployer, stateAddress(".adapterC"), tdC, thC,
            string.concat(RAW, "case-c/task-document.json"), terms());
        ITaskTender(task).fundTask{value: REWARD}(tokenC, REWARD);
        vm.stopBroadcast();

        require(ITaskTender(task).escrowBalanceOf(tokenB) == REWARD && ITaskTender(task).escrowBalanceOf(tokenC) == REWARD, "escrow");
        vm.writeJson(vm.toString(tokenB), stateFile(), ".tokenB");
        vm.writeJson(vm.toString(tokenC), stateFile(), ".tokenC");
        vm.writeJson(vm.toString(tdB), stateFile(), ".tdHashB");
        vm.writeJson(vm.toString(thB), stateFile(), ".taskHashB");
        vm.writeJson(vm.toString(tdC), stateFile(), ".tdHashC");
        vm.writeJson(vm.toString(thC), stateFile(), ".taskHashC");
        console2.log("tokenB", tokenB);
        console2.log("tokenC", tokenC);
    }
}

/// Run 3: submissions, cases, clearance, on-chain and signed ballots, settlements.
contract OpenCasesR3 is CaseBaseR3 {
    function run() external {
        uint256 pk = deployerKey();
        (uint256[5] memory jk, uint256 workerKey) = caseKeys();
        address task = stateAddress(".taskToken");
        IACDFRegistry reg = IACDFRegistry(stateAddress(".registry"));
        ACDFTaskTenderAdapter adapterB = ACDFTaskTenderAdapter(stateAddress(".adapterB"));
        ACDFTaskTenderAdapter adapterC = ACDFTaskTenderAdapter(stateAddress(".adapterC"));
        uint256 tokenB = stateUint(".tokenB");
        uint256 tokenC = stateUint(".tokenC");
        bytes32 resB = fileHash("deployments/case-b/result.json");
        bytes32 resC = fileHash("deployments/case-c/result.json");

        vm.startBroadcast(workerKey);
        uint256 subB = ITaskTender(task).submitFulfillment(tokenB, resB, string.concat(RAW, "case-b/result.json"));
        uint256 subC = ITaskTender(task).submitFulfillment(tokenC, resC, string.concat(RAW, "case-c/result.json"));
        vm.stopBroadcast();

        vm.startBroadcast(pk);
        bytes32 issueB = adapterB.open(tokenB, subB);
        bytes32 issueC = adapterC.open(tokenC, subC);
        vm.stopBroadcast();

        // Case B, screening body (body 0): both members block = explicit clearance of the veto.
        uint256[] memory keysS = new uint256[](2);
        keysS[0] = jk[3]; keysS[1] = jk[4];
        bool[] memory appS = new bool[](2);
        appS[0] = false; appS[1] = false;
        (address[] memory vS, bytes[] memory sS) = signedBallots(reg, issueB, keysS, appS);
        // Case C, body 0: jurors 1-3 block.
        uint256[] memory keysC = new uint256[](3);
        keysC[0] = jk[0]; keysC[1] = jk[1]; keysC[2] = jk[2];
        bool[] memory appC = new bool[](3);
        appC[0] = false; appC[1] = false; appC[2] = false;
        (address[] memory vC, bytes[] memory sC) = signedBallots(reg, issueC, keysC, appC);

        uint32 round = reg.getResult(issueB).roundCount; // 1
        vm.startBroadcast(pk);
        reg.submitSignedBallots(issueB, 0, vS, appS, sS);
        vm.stopBroadcast();
        // technical chamber (body 1): jurors 1 and 2 approve on chain; economic chamber (body 2): jurors 4 and 5
        vm.startBroadcast(jk[0]); reg.castBallot(issueB, round, 1, true); vm.stopBroadcast();
        vm.startBroadcast(jk[1]); reg.castBallot(issueB, round, 1, true); vm.stopBroadcast();
        vm.startBroadcast(jk[3]); reg.castBallot(issueB, round, 2, true); vm.stopBroadcast();
        vm.startBroadcast(jk[4]); reg.castBallot(issueB, round, 2, true); vm.stopBroadcast();
        vm.startBroadcast(pk);
        reg.settleRound(issueB);
        reg.submitSignedBallots(issueC, 0, vC, appC, sC);
        reg.settleRound(issueC);
        vm.stopBroadcast();

        (uint64 openB, uint64 openC) = checkProvisional(reg, issueB, issueC, round);
        record(subB, subC, resB, resC, issueB, issueC, openB, openC);
        console2.log("run FinalizeR3 after both, plus a minute");
    }

    /// Provisional results carry their outcome in the round record until finalize adopts it.
    function checkProvisional(IACDFRegistry reg, bytes32 issueB, bytes32 issueC, uint32 round)
        internal view returns (uint64 openB, uint64 openC)
    {
        T.RoundState memory roundB = reg.getRound(issueB, round);
        require(reg.getResult(issueB).state == T.ProcedureState.Provisional && roundB.status == T.NodeStatus.Yes, "B not Provisional(Yes)");
        (T.NodeStatus vetoNode, , ) = reg.nodeStatus(issueB, round, 0);
        require(vetoNode == T.NodeStatus.Yes, "B root");
        require(roundB.at < roundB.startedAt + WINDOW_B_SCREEN, "B should have passed before the veto window closed");
        T.RoundState memory roundC = reg.getRound(issueC, round);
        require(reg.getResult(issueC).state == T.ProcedureState.Provisional && roundC.status == T.NodeStatus.No, "C not Provisional(No)");
        openB = roundB.appealOpenUntil;
        openC = roundC.appealOpenUntil;
    }

    function record(uint256 subB, uint256 subC, bytes32 resB, bytes32 resC, bytes32 issueB, bytes32 issueC, uint64 openB, uint64 openC) internal {
        vm.writeJson(vm.toString(subB), stateFile(), ".submissionB");
        vm.writeJson(vm.toString(subC), stateFile(), ".submissionC");
        vm.writeJson(vm.toString(resB), stateFile(), ".resultHashB");
        vm.writeJson(vm.toString(resC), stateFile(), ".resultHashC");
        vm.writeJson(vm.toString(issueB), stateFile(), ".issueB");
        vm.writeJson(vm.toString(issueC), stateFile(), ".issueC");
        vm.writeJson(vm.toString(openB), stateFile(), ".appealOpenUntilB");
        vm.writeJson(vm.toString(openC), stateFile(), ".appealOpenUntilC");
        console2.log("issueB", vm.toString(issueB));
        console2.log("issueC", vm.toString(issueC));
        console2.log("B appealOpenUntil (simulation estimate)", openB);
        console2.log("C appealOpenUntil (simulation estimate)", openC);
    }
}

/// Run 4: B finalizes and pays; C finalizes as No and the adapter rejects through the kernel.
contract FinalizeR3 is CaseBaseR3 {
    function run() external {
        uint256 pk = deployerKey();
        (, uint256 workerKey) = caseKeys();
        address worker = vm.addr(workerKey);
        address task = stateAddress(".taskToken");
        IACDFRegistry reg = IACDFRegistry(stateAddress(".registry"));
        ACDFTaskTenderAdapter adapterB = ACDFTaskTenderAdapter(stateAddress(".adapterB"));
        ACDFTaskTenderAdapter adapterC = ACDFTaskTenderAdapter(stateAddress(".adapterC"));
        bytes32 issueB = stateBytes32(".issueB");
        bytes32 issueC = stateBytes32(".issueC");
        uint256 tokenB = stateUint(".tokenB");
        uint256 tokenC = stateUint(".tokenC");
        require(block.timestamp > stateUint(".appealOpenUntilB") && block.timestamp > stateUint(".appealOpenUntilC"), "appeal windows still open");

        uint256 before = worker.balance;
        uint256 escrowC = ITaskTender(task).escrowBalanceOf(tokenC);
        vm.startBroadcast(pk);
        reg.finalize(issueB);
        adapterB.execute(issueB);
        reg.finalize(issueC);
        adapterC.execute(issueC);
        vm.stopBroadcast();

        T.Result memory b = reg.getResult(issueB);
        require(b.state == T.ProcedureState.Final && b.outcomeType == T.OutcomeType.Decided && b.outcomeYes && !b.adoptedFromEarlierRound, "B");
        require(ITaskTender(task).submissionOf(tokenB, stateUint(".submissionB")).status == ITaskTender.SubmissionStatus.Accepted, "B accepted");
        require(reg.getEnactment(issueB, address(adapterB), adapterB.EFFECT_ACCEPT()).status == T.EnactmentStatus.Enacted, "B enacted");
        if (ITaskTender(task).creditOf(tokenB, worker) == 0) require(worker.balance == before + REWARD, "B paid");

        T.Result memory c = reg.getResult(issueC);
        require(c.state == T.ProcedureState.Final && c.outcomeType == T.OutcomeType.Decided && !c.outcomeYes && !c.adoptedFromEarlierRound, "C");
        require(ITaskTender(task).submissionOf(tokenC, stateUint(".submissionC")).status == ITaskTender.SubmissionStatus.Rejected, "C rejected");
        require(reg.getEnactment(issueC, address(adapterC), adapterC.EFFECT_REJECT()).status == T.EnactmentStatus.Enacted, "C enacted");
        require(ITaskTender(task).pendingOf(tokenC) == 0, "C slot released");
        require(ITaskTender(task).escrowBalanceOf(tokenC) == escrowC, "C escrow untouched");
        require(ITaskTender(task).creditOf(tokenC, worker) == 0, "C nothing credited");

        vm.writeJson("true", stateFile(), ".done");
        logResult("Case B", reg, issueB);
        logResult("Case C", reg, issueC);
    }
}
