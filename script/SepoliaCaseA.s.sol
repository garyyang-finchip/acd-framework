// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// Sepolia deployment (revision 2) and two live cases against the ERC-8414 reference TaskToken.
///
/// Four runs, in order (see docs/sepolia-runbook.md):
///   1. DeployCore   deployer: ACDFPolicyRegistry, ACDFRegistry, policy A (PRESERVE_UNLESS_OVERTURNED)
///                   and policy A2 (REQUIRE_FRESH_DECISION), one ACDFTaskTenderAdapter per policy;
///                   funds the worker account with gas money.
///   2. MintTasks    deployer: mints task A (adapter A as acceptance authority) and task A2 (adapter
///                   A2), funds both escrows.
///   3. OpenCases    worker submits on both tasks; deployer opens both cases, relays signed ballots
///                   (A: one No + three Yes; A2: three Yes), settles both rounds -> Provisional, and
///                   appeals A2 -> round 2 Deciding.
///   4. Finalize     after the windows: A finalize -> Final x Decided(Yes), execute -> acceptFulfillment
///                   pays the worker. A2: round 2 ends without ballots -> settle -> Final x NoDecision
///                   (REQUIRE_FRESH_DECISION vacated round 1); execute is refused; the submission stays
///                   Pending under the tender's own judgment clock.
///
/// State between runs lives in deployments/sepolia.json (deployments/local-<chainId>.json on a
/// local rehearsal). Accounts: DEPLOYER_PK (funded), CASE_MNEMONIC (indices 0-4 jurors, 5 worker;
/// jurors only sign). ACDF_AUTHORITY is the update authority of both policy families.

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
}

abstract contract CaseBase is Script {
    address constant LIVE_TASK_TOKEN = 0xA62059A498E40C4Ae4aF926E2B00C1Ff122bDdb7; // Sepolia ERC-8414
    uint64  constant MARGIN           = 1800;
    uint32  constant K                = 3;          // 3-of-5
    uint256 constant REWARD           = 0.001 ether;
    uint64  constant JUDGMENT_WINDOW  = 2 days;
    uint256 constant WORKER_GAS_MONEY = 0.003 ether;
    string  constant RAW = "https://raw.githubusercontent.com/garyyang-finchip/acd-framework/main/deployments/";

    // Case A: PRESERVE_UNLESS_OVERTURNED, one appeal, 10-minute appeal window, 1-hour body window
    bytes32 constant FAMILY_A  = keccak256("acdf.sepolia.case-a");
    uint64  constant WINDOW_A  = 3600;
    uint64  constant APPEAL_A  = 600;
    uint64  constant TOTAL_A   = 10800;
    // Case A2: REQUIRE_FRESH_DECISION, one appeal, 10-minute appeal window, 15-minute body window
    bytes32 constant FAMILY_A2 = keccak256("acdf.sepolia.case-a2");
    uint64  constant WINDOW_A2 = 900;
    uint64  constant APPEAL_A2 = 600;
    uint64  constant TOTAL_A2  = 3600;

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

    function policySpec(address authority, bytes32 family, uint64 window, uint64 appealWindow, uint64 total,
                        T.AppealMode mode, string memory descriptor) internal view returns (T.PolicySpec memory s) {
        T.BodySpec[] memory bodies = new T.BodySpec[](1);
        bodies[0].kind = T.BodyKind.ROSTER_KOFN;
        bodies[0].acceptance = T.Acceptance.SIGNED_BALLOTS;
        bodies[0].members = jurorAddresses();
        bodies[0].k = K;
        bodies[0].window = window;
        T.Node[] memory nodes = new T.Node[](1);
        nodes[0].op = T.Combinator.BODY;
        nodes[0].children = new uint32[](0);
        s.family = family;
        s.version = 1;
        s.updateAuthority = authority;
        s.bodies = bodies;
        s.nodes = nodes;
        s.maxAppeals = 1;
        s.appealWindow = appealWindow;
        s.appealable = 1; // Decided results appealable
        s.appealStanding = T.AppealStanding.ANYONE;
        s.appealMode = mode;
        s.maxTotalDuration = total;
        s.ackWindow = 0;
        s.allowAdvisory = false;
        s.descriptorHash = fileHash(descriptor);
    }

    function fileHash(string memory path) internal view returns (bytes32) {
        return keccak256(bytes(vm.readFile(path)));
    }

    function stateFile() internal view returns (string memory) {
        if (block.chainid == 11155111) return "deployments/sepolia.json";
        return string(abi.encodePacked("deployments/local-", vm.toString(block.chainid), ".json"));
    }
    function stateAddress(string memory key) internal view returns (address) { return vm.parseJsonAddress(vm.readFile(stateFile()), key); }
    function stateBytes32(string memory key) internal view returns (bytes32) { return vm.parseJsonBytes32(vm.readFile(stateFile()), key); }
    function stateUint(string memory key) internal view returns (uint256) { return vm.parseJsonUint(vm.readFile(stateFile()), key); }

    function terms() internal pure returns (ITaskTender.TenderTerms memory) {
        return ITaskTender.TenderTerms({asset: address(0), rewardPerCompletion: REWARD, maxCompletions: 1,
            submitBy: 0, settleBy: 0, epochLength: 0, maxCompletionsPerEpoch: 0, judgmentWindow: JUDGMENT_WINDOW});
    }

    function signedBallots(IACDFRegistry reg, bytes32 issueId, uint256[] memory keys, bool[] memory approves)
        internal view returns (address[] memory voters, bytes[] memory sigs)
    {
        uint32 round = reg.getResult(issueId).roundCount;
        voters = new address[](keys.length);
        sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            voters[i] = vm.addr(keys[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], reg.ballotDigest(issueId, round, 0, voters[i], approves[i]));
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    function logResult(string memory label, IACDFRegistry reg, bytes32 issueId) internal view {
        T.Result memory r = reg.getResult(issueId);
        console2.log(label);
        console2.log("  state/outcomeType/outcomeYes", uint8(r.state), uint8(r.outcomeType), r.outcomeYes);
        console2.log("  reason/roundCount/sourceRound", uint8(r.reason), r.roundCount, r.sourceRound);
        console2.log("  decidedAt/finalAt/adoptedFromEarlierRound", r.decidedAt, r.finalAt, r.adoptedFromEarlierRound);
    }
}

/// Run 1: core deployment, two policies, two adapters, worker gas money.
contract DeployCore is CaseBase {
    function run() external {
        address authority = vm.envAddress("ACDF_AUTHORITY");
        uint256 pk = deployerKey();
        (, uint256 workerKey) = caseKeys();
        address worker = vm.addr(workerKey);
        address task = taskToken();

        vm.startBroadcast(pk);
        if (task == address(0)) task = address(new TaskToken("Task Token", "TASK")); // local rehearsal only
        ACDFPolicyRegistry pol = new ACDFPolicyRegistry();
        ACDFRegistry reg = new ACDFRegistry(IACDFPolicyRegistry(address(pol)));
        T.PolicySpec memory specA = policySpec(authority, FAMILY_A, WINDOW_A, APPEAL_A, TOTAL_A,
            T.AppealMode.PRESERVE_UNLESS_OVERTURNED, "deployments/case-a/policy-descriptor.json");
        T.PolicySpec memory specA2 = policySpec(authority, FAMILY_A2, WINDOW_A2, APPEAL_A2, TOTAL_A2,
            T.AppealMode.REQUIRE_FRESH_DECISION, "deployments/case-a2/policy-descriptor.json");
        bytes32 policyA = pol.registerPolicy(specA);
        bytes32 policyA2 = pol.registerPolicy(specA2);
        ACDFTaskTenderAdapter adapterA = new ACDFTaskTenderAdapter(IACDFRegistry(address(reg)), ITaskTender8414(task), policyA, MARGIN);
        ACDFTaskTenderAdapter adapterA2 = new ACDFTaskTenderAdapter(IACDFRegistry(address(reg)), ITaskTender8414(task), policyA2, MARGIN);
        payable(worker).transfer(WORKER_GAS_MONEY);
        vm.stopBroadcast();

        require(policyA == pol.policyIdOf(specA) && policyA2 == pol.policyIdOf(specA2), "policyId mismatch");
        require(pol.familyAuthority(FAMILY_A) == authority && pol.familyAuthority(FAMILY_A2) == authority, "authority");
        require(uint8(pol.timingOf(policyA2).appealMode) == uint8(T.AppealMode.REQUIRE_FRESH_DECISION), "mode");

        string memory j = "state";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", vm.addr(pk));
        vm.serializeAddress(j, "authority", authority);
        vm.serializeAddress(j, "taskToken", task);
        vm.serializeAddress(j, "policyRegistry", address(pol));
        vm.serializeAddress(j, "registry", address(reg));
        vm.serializeAddress(j, "adapterA", address(adapterA));
        vm.serializeAddress(j, "adapterA2", address(adapterA2));
        vm.serializeBytes32(j, "policyA", policyA);
        vm.serializeBytes32(j, "policyA2", policyA2);
        vm.serializeBytes32(j, "descriptorHashA", specA.descriptorHash);
        vm.serializeBytes32(j, "descriptorHashA2", specA2.descriptorHash);
        vm.serializeAddress(j, "worker", worker);
        string memory out = vm.serializeAddress(j, "jurors", jurorAddresses());
        vm.writeJson(out, stateFile());

        console2.log("policyRegistry", address(pol));
        console2.log("registry      ", address(reg));
        console2.log("adapterA      ", address(adapterA));
        console2.log("adapterA2     ", address(adapterA2));
        console2.log("policyA       ", vm.toString(policyA));
        console2.log("policyA2      ", vm.toString(policyA2));
        console2.log("worker        ", worker);
    }
}

/// Run 2: mint both tasks with their adapters as acceptance authority and fund the escrows.
contract MintTasks is CaseBase {
    function run() external {
        uint256 pk = deployerKey();
        address deployer = vm.addr(pk);
        address task = stateAddress(".taskToken");
        bytes32 tdA = fileHash("deployments/case-a/task-document.json");
        bytes32 tdA2 = fileHash("deployments/case-a2/task-document.json");
        bytes32 thA = keccak256(abi.encodePacked("acdf.case-a.task.v1", tdA));
        bytes32 thA2 = keccak256(abi.encodePacked("acdf.case-a2.task.v1", tdA2));

        vm.startBroadcast(pk);
        uint256 tokenA = ITaskTokenMint(task).mintTask(deployer, deployer, stateAddress(".adapterA"), tdA, thA,
            string.concat(RAW, "case-a/task-document.json"), terms());
        ITaskTender(task).fundTask{value: REWARD}(tokenA, REWARD);
        uint256 tokenA2 = ITaskTokenMint(task).mintTask(deployer, deployer, stateAddress(".adapterA2"), tdA2, thA2,
            string.concat(RAW, "case-a2/task-document.json"), terms());
        ITaskTender(task).fundTask{value: REWARD}(tokenA2, REWARD);
        vm.stopBroadcast();

        require(ITaskTender(task).escrowBalanceOf(tokenA) == REWARD && ITaskTender(task).escrowBalanceOf(tokenA2) == REWARD, "escrow");
        vm.writeJson(vm.toString(tokenA), stateFile(), ".tokenA");
        vm.writeJson(vm.toString(tokenA2), stateFile(), ".tokenA2");
        vm.writeJson(vm.toString(tdA), stateFile(), ".tdHashA");
        vm.writeJson(vm.toString(thA), stateFile(), ".taskHashA");
        vm.writeJson(vm.toString(tdA2), stateFile(), ".tdHashA2");
        vm.writeJson(vm.toString(thA2), stateFile(), ".taskHashA2");
        console2.log("tokenA ", tokenA);
        console2.log("tokenA2", tokenA2);
    }
}

/// Run 3: submissions, cases, ballots, settlements; A2 is appealed.
contract OpenCases is CaseBase {
    function run() external {
        uint256 pk = deployerKey();
        (uint256[5] memory jk, uint256 workerKey) = caseKeys();
        address task = stateAddress(".taskToken");
        IACDFRegistry reg = IACDFRegistry(stateAddress(".registry"));
        ACDFTaskTenderAdapter adapterA = ACDFTaskTenderAdapter(stateAddress(".adapterA"));
        ACDFTaskTenderAdapter adapterA2 = ACDFTaskTenderAdapter(stateAddress(".adapterA2"));
        uint256 tokenA = stateUint(".tokenA");
        uint256 tokenA2 = stateUint(".tokenA2");
        bytes32 resA = fileHash("deployments/case-a/result.json");
        bytes32 resA2 = fileHash("deployments/case-a2/result.json");

        vm.startBroadcast(workerKey);
        uint256 subA = ITaskTender(task).submitFulfillment(tokenA, resA, string.concat(RAW, "case-a/result.json"));
        uint256 subA2 = ITaskTender(task).submitFulfillment(tokenA2, resA2, string.concat(RAW, "case-a2/result.json"));
        vm.stopBroadcast();

        vm.startBroadcast(pk);
        bytes32 issueA = adapterA.open(tokenA, subA);
        bytes32 issueA2 = adapterA2.open(tokenA2, subA2);
        vm.stopBroadcast();

        // Case A: juror 4 blocks first, jurors 1-3 approve
        uint256[] memory keysA = new uint256[](4);
        keysA[0] = jk[3]; keysA[1] = jk[0]; keysA[2] = jk[1]; keysA[3] = jk[2];
        bool[] memory appA = new bool[](4);
        appA[0] = false; appA[1] = true; appA[2] = true; appA[3] = true;
        (address[] memory vA, bytes[] memory sA) = signedBallots(reg, issueA, keysA, appA);
        // Case A2: jurors 1-3 approve
        uint256[] memory keysA2 = new uint256[](3);
        keysA2[0] = jk[0]; keysA2[1] = jk[1]; keysA2[2] = jk[2];
        bool[] memory appA2 = new bool[](3);
        appA2[0] = true; appA2[1] = true; appA2[2] = true;
        (address[] memory vA2, bytes[] memory sA2) = signedBallots(reg, issueA2, keysA2, appA2);

        vm.startBroadcast(pk);
        reg.submitSignedBallots(issueA, 0, vA, appA, sA);
        reg.settleRound(issueA);
        reg.submitSignedBallots(issueA2, 0, vA2, appA2, sA2);
        reg.settleRound(issueA2);
        reg.appeal(issueA2); // the round-1 Yes is challenged; under REQUIRE_FRESH_DECISION it is now vacated
        vm.stopBroadcast();

        require(reg.getResult(issueA).state == T.ProcedureState.Provisional, "A not provisional");
        require(reg.getResult(issueA2).state == T.ProcedureState.Deciding && reg.getResult(issueA2).roundCount == 2, "A2 not in round 2");
        T.RoundState memory rA = reg.getRound(issueA, 1);
        T.RoundState memory rA2 = reg.getRound(issueA2, 2);

        vm.writeJson(vm.toString(subA), stateFile(), ".submissionA");
        vm.writeJson(vm.toString(subA2), stateFile(), ".submissionA2");
        vm.writeJson(vm.toString(resA), stateFile(), ".resultHashA");
        vm.writeJson(vm.toString(resA2), stateFile(), ".resultHashA2");
        vm.writeJson(vm.toString(issueA), stateFile(), ".issueA");
        vm.writeJson(vm.toString(issueA2), stateFile(), ".issueA2");
        vm.writeJson(vm.toString(rA.appealOpenUntil), stateFile(), ".appealOpenUntilA");
        vm.writeJson(vm.toString(rA2.startedAt + WINDOW_A2), stateFile(), ".round2ClosesA2");
        console2.log("issueA ", vm.toString(issueA));
        console2.log("issueA2", vm.toString(issueA2));
        console2.log("A  appealOpenUntil (simulation estimate)", rA.appealOpenUntil);
        console2.log("A2 round 2 closes  (simulation estimate)", rA2.startedAt + WINDOW_A2);
        console2.log("run Finalize after both, plus a minute");
    }
}

/// Run 4: A finalizes and executes; A2's appeal round ends empty and finalizes as NoDecision.
contract Finalize is CaseBase {
    function run() external {
        uint256 pk = deployerKey();
        (, uint256 workerKey) = caseKeys();
        address worker = vm.addr(workerKey);
        address task = stateAddress(".taskToken");
        IACDFRegistry reg = IACDFRegistry(stateAddress(".registry"));
        ACDFTaskTenderAdapter adapterA = ACDFTaskTenderAdapter(stateAddress(".adapterA"));
        ACDFTaskTenderAdapter adapterA2 = ACDFTaskTenderAdapter(stateAddress(".adapterA2"));
        bytes32 issueA = stateBytes32(".issueA");
        bytes32 issueA2 = stateBytes32(".issueA2");
        require(block.timestamp > stateUint(".appealOpenUntilA") && block.timestamp > stateUint(".round2ClosesA2"), "windows still open");

        uint256 before = worker.balance;
        vm.startBroadcast(pk);
        reg.finalize(issueA);
        adapterA.execute(issueA);
        reg.settleRound(issueA2); // round 2: no ballots -> NoDecision(QUORUM_NOT_MET); fresh mode -> Final x NoDecision
        vm.stopBroadcast();

        T.Result memory a = reg.getResult(issueA);
        require(a.state == T.ProcedureState.Final && a.outcomeType == T.OutcomeType.Decided && a.outcomeYes && !a.adoptedFromEarlierRound, "A");
        require(ITaskTender(task).submissionOf(stateUint(".tokenA"), stateUint(".submissionA")).status == ITaskTender.SubmissionStatus.Accepted, "A accepted");
        if (ITaskTender(task).creditOf(stateUint(".tokenA"), worker) == 0) require(worker.balance == before + REWARD, "A paid");

        T.Result memory b = reg.getResult(issueA2);
        require(b.state == T.ProcedureState.Final && b.outcomeType == T.OutcomeType.NoDecision, "A2 not NoDecision");
        require(b.reason == T.Reason.QUORUM_NOT_MET && b.roundCount == 2 && b.sourceRound == 2 && !b.adoptedFromEarlierRound, "A2 fields");
        require(reg.getRound(issueA2, 1).status == T.NodeStatus.Yes, "A2 round 1 Yes is on record, vacated");
        // execution is refused: no decision, the tender's own judgment clock governs
        (bool ok, ) = address(adapterA2).staticcall(abi.encodeCall(adapterA2.execute, (issueA2)));
        require(!ok, "A2 execute must be refused");
        require(ITaskTender(task).submissionOf(stateUint(".tokenA2"), stateUint(".submissionA2")).status == ITaskTender.SubmissionStatus.Pending, "A2 still pending");

        vm.writeJson("true", stateFile(), ".done");
        logResult("Case A", reg, issueA);
        logResult("Case A2", reg, issueA2);
    }
}
