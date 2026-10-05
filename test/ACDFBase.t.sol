// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";
import {ACDFPolicyRegistry} from "../assets/erc-acdf/contracts/ACDFPolicyRegistry.sol";
import {ACDFRegistry} from "../assets/erc-acdf/contracts/ACDFRegistry.sol";
import {IACDFPolicyRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFPolicyRegistry.sol";

/// Shared fixtures: policy builders and issue helpers used by every test group.
abstract contract ACDFBase is Test {
    ACDFPolicyRegistry pol;
    ACDFRegistry reg;

    address authority = address(0xA07);
    address consumer  = address(0xC0115);
    address filer     = address(0xF11E);
    address rando     = address(0xBAD);

    // five roster members with known private keys (for signed ballots)
    uint256[] pk;
    address[] members;

    bytes32 constant Q      = keccak256("question.v1");
    bytes32 constant E_YES  = keccak256("effect.yes");
    bytes32 constant E_NO   = keccak256("effect.no");
    bytes32 constant DISP   = keccak256("disposition.status-quo");
    bytes32 constant FAMILY = keccak256("family.test");

    function setUp() public virtual {
        pol = new ACDFPolicyRegistry();
        reg = new ACDFRegistry(pol);
        for (uint256 i = 0; i < 5; i++) {
            uint256 k = uint256(keccak256(abi.encode("juror", i)));
            pk.push(k);
            members.push(vm.addr(k));
        }
        vm.warp(1_800_000_000);
    }

    // ------------------------------------------------------------------ builders

    function roster(uint256 n) internal view returns (address[] memory r) {
        r = new address[](n);
        for (uint256 i = 0; i < n; i++) r[i] = members[i];
    }

    function rosterBody(uint256 n, uint32 k, uint64 window, T.Acceptance acc) internal view returns (T.BodySpec memory b) {
        b.kind = T.BodyKind.ROSTER_KOFN;
        b.acceptance = acc;
        b.members = roster(n);
        b.k = k;
        b.window = window;
    }

    function submitterBody(address submitter, uint64 window) internal pure returns (T.BodySpec memory b) {
        b.kind = T.BodyKind.AUTHORIZED_SUBMITTER;
        b.acceptance = T.Acceptance.AUTHORIZED_SUBMITTER;
        b.members = new address[](1);
        b.members[0] = submitter;
        b.k = 0;
        b.window = window;
    }

    function bodyNode(uint32 body) internal pure returns (T.Node memory n) {
        n.op = T.Combinator.BODY;
        n.body = body;
        n.children = new uint32[](0);
    }

    function combNode(T.Combinator op, uint32 k, uint32[] memory children) internal pure returns (T.Node memory n) {
        n.op = op;
        n.k = k;
        n.children = children;
    }

    function vetoNode(uint32 target, uint32 vetoBody, T.VetoSilence silence) internal pure returns (T.Node memory n) {
        n.op = T.Combinator.VETO;
        n.target = target;
        n.vetoBody = vetoBody;
        n.silence = silence;
        n.children = new uint32[](0);
    }

    function u32(uint32 a, uint32 b) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](2); arr[0] = a; arr[1] = b;
    }

    function u32(uint32 a, uint32 b, uint32 c) internal pure returns (uint32[] memory arr) {
        arr = new uint32[](3); arr[0] = a; arr[1] = b; arr[2] = c;
    }

    /// Minimal single-body policy skeleton: fills family/version/authority/timing with defaults.
    function spec(T.BodySpec[] memory bodies, T.Node[] memory nodes, bytes32 family) internal view returns (T.PolicySpec memory s) {
        s.family = family;
        s.version = 1;
        s.previous = bytes32(0);
        s.updateAuthority = authority;
        s.bodies = bodies;
        s.nodes = nodes;
        s.maxAppeals = 0;
        s.appealWindow = 0;
        s.appealable = 0;
        s.appealStanding = T.AppealStanding.ANYONE;
        s.appealMode = T.AppealMode.PRESERVE_UNLESS_OVERTURNED;
        s.maxTotalDuration = 30 days;
        s.ackWindow = 0;
        s.allowAdvisory = false;
        s.descriptorHash = keccak256("descriptor");
    }

    function minimalSpec(uint256 n, uint32 k, uint64 window) internal view returns (T.PolicySpec memory s) {
        T.BodySpec[] memory bodies = new T.BodySpec[](1);
        bodies[0] = rosterBody(n, k, window, T.Acceptance.ON_CHAIN_TALLY);
        T.Node[] memory nodes = new T.Node[](1);
        nodes[0] = bodyNode(0);
        s = spec(bodies, nodes, keccak256(abi.encode(FAMILY, n, k, window)));
    }

    function register(T.PolicySpec memory s) internal returns (bytes32 id) {
        vm.prank(authority);
        id = pol.registerPolicy(s);
    }

    function registerMinimal(uint256 n, uint32 k, uint64 window) internal returns (bytes32 id) {
        id = register(minimalSpec(n, k, window));
    }

    // ------------------------------------------------------------------ issues

    function subject(uint256 id) internal view returns (T.Subject memory s) {
        s.chainId = block.chainid;
        s.target = address(0x7A5);
        s.id = id;
        s.dataHash = keccak256(abi.encode("data", id));
    }

    function consumerInput(bytes32 policyId, uint256 id, uint64 deadline) internal view returns (T.IssueInput memory i) {
        i.policyId = policyId;
        i.mode = T.AcceptanceMode.CONSUMER_FILED;
        i.consumer = consumer;
        i.subject = subject(id);
        i.question = Q;
        i.effectYes = E_YES;
        i.effectNo = E_NO;
        i.disposition = DISP;
        i.obligationId = obligationOf(id);
        i.consumerDeadline = deadline;
    }

    /// Default obligation scope of the fixtures: one obligation per subject id.
    function obligationOf(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode("obligation", id));
    }

    function fileAsConsumer(bytes32 policyId, uint256 id) internal returns (bytes32 issueId) {
        vm.prank(consumer);
        issueId = reg.file(consumerInput(policyId, id, 0));
    }

    function vote(bytes32 issueId, uint32 body, uint256 memberIdx, bool approve) internal {
        uint32 round = reg.getResult(issueId).roundCount; // read before the prank so the prank reaches castBallot
        vm.prank(members[memberIdx]);
        reg.castBallot(issueId, round, body, approve);
    }

    function result(bytes32 issueId) internal view returns (T.Result memory) { return reg.getResult(issueId); }

    function assertFinalDecided(bytes32 issueId, bool yes) internal view {
        T.Result memory r = reg.getResult(issueId);
        assertEq(uint8(r.state), uint8(T.ProcedureState.Final), "state");
        assertEq(uint8(r.outcomeType), uint8(T.OutcomeType.Decided), "outcomeType");
        assertEq(r.outcomeYes, yes, "outcomeYes");
    }

    function assertFinalNoDecision(bytes32 issueId, T.Reason reason) internal view {
        T.Result memory r = reg.getResult(issueId);
        assertEq(uint8(r.state), uint8(T.ProcedureState.Final), "state");
        assertEq(uint8(r.outcomeType), uint8(T.OutcomeType.NoDecision), "outcomeType");
        assertEq(uint8(r.reason), uint8(reason), "reason");
    }

    function sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
