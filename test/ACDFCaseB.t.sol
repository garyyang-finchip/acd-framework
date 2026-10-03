// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";

/// Design-memo Case B as an executable test: a Swarm-charter parameter change decided by
/// VETO(Screening, 12h, PASS_THROUGH) over ALL(Tech, Econ), one appeal, bound through a
/// STANDING_ACCEPTANCE registered by the governance contract.
///
/// FIXTURE NOTICE. Eligibility is a FIXED ROSTER SNAPSHOT and Tech's "sortition" is a
/// deterministic fixture. This test proves the composition, appeal and binding mechanics;
/// it does NOT verify credit-qualified eligibility (ERC-8419 / ERC-8434), sybil resistance or
/// verifiable random selection, which remain Planned profiles.
contract ACDFCaseBTest is ACDFBase {
    address governance = address(0x60D);   // G: the charter contract (consumer)
    address executor   = address(0xE0E);   // E: receives the adopted effect (modelled as an address here)
    address member     = address(0x3E3);   // M: a member with filing rights

    bytes32 pB;
    bytes32 acceptance;

    bytes32 constant EFFECT_ADOPT  = keccak256("E.schedule(setParam(X,v))");
    bytes32 constant EFFECT_REJECT = keccak256("none");
    bytes32 constant DISP_STATUS_QUO = keccak256("status quo");
    bytes32 constant Q_PARAM = keccak256("PARAM_CHANGE: adopt new value?");

    function chamber(uint256 start, uint256 n, uint32 k, uint64 window, T.Acceptance acc) internal view returns (T.BodySpec memory b) {
        b.kind = T.BodyKind.ROSTER_KOFN; b.acceptance = acc; b.k = k; b.window = window;
        b.members = new address[](n);
        for (uint256 i = 0; i < n; i++) b.members[i] = members[start + i];
    }

    function setUp() public override {
        super.setUp();
        T.BodySpec[] memory bodies = new T.BodySpec[](3);
        bodies[0] = chamber(3, 2, 1, 12 hours, T.Acceptance.ON_CHAIN_TALLY);   // Screening (elders): 1 veto blocks
        bodies[1] = chamber(0, 3, 2, 2 days,   T.Acceptance.SIGNED_BALLOTS);   // Tech chamber: signed ballots, 2-of-3
        bodies[2] = chamber(2, 3, 2, 3 days,   T.Acceptance.ON_CHAIN_TALLY);   // Econ chamber: on-chain, 2-of-3
        T.Node[] memory nodes = new T.Node[](4);
        nodes[0] = vetoNode(1, 0, T.VetoSilence.PASS_THROUGH);
        nodes[1] = combNode(T.Combinator.ALL, 0, u32(2, 3));
        nodes[2] = bodyNode(1);
        nodes[3] = bodyNode(2);
        T.PolicySpec memory s = spec(bodies, nodes, keccak256("swarm.charter.param-change"));
        s.maxAppeals = 1;
        s.appealWindow = 2 days;
        s.appealable = 3;                       // Decided and NoDecision are both appealable
        s.appealStanding = T.AppealStanding.ANYONE; // any member may appeal; modelled as ANYONE in the fixture
        s.maxTotalDuration = 10 days;           // (1+1)*3d + 1*2d = 8d needed
        pB = register(s);

        T.StandingAcceptanceInput memory a;
        a.policyId = pB;
        a.subjectTarget = governance;           // subject = (G, paramId, newValue)
        a.question = Q_PARAM;
        a.filers = new address[](1); a.filers[0] = member;
        a.effectYes = EFFECT_ADOPT;
        a.effectNo = EFFECT_REJECT;
        a.disposition = DISP_STATUS_QUO;
        a.validUntil = 0;
        vm.prank(governance);
        acceptance = reg.registerStandingAcceptance(a);
    }

    function fileParamChange(uint256 paramId, uint256 newValue) internal returns (bytes32 id) {
        T.IssueInput memory i;
        i.policyId = pB;
        i.mode = T.AcceptanceMode.STANDING_ACCEPTANCE;
        i.acceptanceId = acceptance;
        i.subject = T.Subject({chainId: block.chainid, target: governance, id: paramId, dataHash: keccak256(abi.encode(newValue))});
        i.question = Q_PARAM;
        vm.prank(member);
        id = reg.file(i);
    }

    function techSigned(bytes32 id, bool approve) internal {
        uint32 round = reg.getIssue(id).roundCount;
        address[] memory v = new address[](2); v[0] = members[0]; v[1] = members[1];
        bool[] memory a = new bool[](2); a[0] = approve; a[1] = approve;
        bytes[] memory s = new bytes[](2);
        s[0] = sign(pk[0], reg.ballotDigest(id, round, 1, members[0], approve));
        s[1] = sign(pk[1], reg.ballotDigest(id, round, 1, members[1], approve));
        reg.submitSignedBallots(id, 1, v, a, s);
    }

    function econ(bytes32 id, bool approve) internal { vote(id, 2, 3, approve); vote(id, 2, 4, approve); }

    function test_caseB_main_path_veto_silent_both_chambers_adopt_appeal_then_final() public {
        bytes32 id = fileParamChange(7, 42);
        T.Issue memory it = reg.getIssue(id);
        assertEq(it.consumer, governance, "the charter contract is the bound consumer");
        assertEq(it.effectYes, EFFECT_ADOPT, "effects are the charter's commitment, not the member's");
        assertEq(it.disposition, DISP_STATUS_QUO);
        assertEq(uint8(it.effectClass), uint8(T.EffectClass.Binding));

        // hour 1: both chambers approve; nothing can be settled while the elders' 12h veto right lives
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        techSigned(id, true);
        econ(id, true);
        vm.expectRevert("ACDF: pending");
        reg.settleRound(id);

        // hour 13: veto window closed in silence → PASS_THROUGH → provisional adoption
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        reg.settleRound(id);
        assertEq(uint8(result(id).state), uint8(T.ProcedureState.Provisional));

        // a member appeals within 48h; round 2 re-runs every body under the same policy
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(member);
        reg.appeal(id);
        assertEq(reg.getIssue(id).roundCount, 2);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        techSigned(id, true);
        econ(id, true);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        reg.settleRound(id);                 // appeals exhausted → Final
        assertFinalDecided(id, true);
        assertEq(result(id).sourceRound, 2);

        // the consumer enacts within its own authority and logs it
        vm.prank(governance);
        reg.recordEnactment(id, EFFECT_ADOPT, T.EnactmentStatus.Enacted, keccak256("E.schedule tx"));
        assertEq(uint8(reg.getEnactment(id, governance, EFFECT_ADOPT).status), uint8(T.EnactmentStatus.Enacted));
        vm.prank(executor); // anyone else is refused
        vm.expectRevert("ACDF: not the consumer");
        reg.recordEnactment(id, EFFECT_ADOPT, T.EnactmentStatus.Enacted, bytes32(0));
    }

    function test_caseB_variant1_elders_veto_inside_the_window() public {
        bytes32 id = fileParamChange(7, 42);
        techSigned(id, true);
        econ(id, true);
        vm.warp(vm.getBlockTimestamp() + 11 hours);
        vote(id, 0, 3, true);  // one elder vetoes
        reg.settleRound(id);   // Decided(reject, VETOED) → provisional
        assertEq(uint8(result(id).state), uint8(T.ProcedureState.Provisional));
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        reg.finalize(id);
        assertFinalDecided(id, false);
        assertEq(uint8(result(id).reason), uint8(T.Reason.VETOED));
    }

    function test_caseB_variant2_econ_quorum_not_met_is_NoDecision_not_rejection() public {
        bytes32 id = fileParamChange(7, 42);
        techSigned(id, true);
        vote(id, 2, 3, true);                      // only one Econ member shows up
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        reg.settleRound(id);                       // NoDecision is appealable here → provisional
        T.RoundState memory r1 = reg.getRound(id, 1);
        assertEq(uint8(r1.status), uint8(T.NodeStatus.NoDecision));
        assertEq(uint8(r1.reason), uint8(T.Reason.NOT_REACHED), "required joint approval not formed");
        (T.NodeStatus tech,,) = reg.bodyStatus(id, 1, 1);
        assertEq(uint8(tech), uint8(T.NodeStatus.Yes), "Tech's approval stays on record as evidence only");
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        reg.finalize(id);
        assertFinalNoDecision(id, T.Reason.NOT_REACHED);
        // status quo: nothing to enact; the consumer could log nothing for a NoDecision
        vm.prank(governance);
        vm.expectRevert("ACDF: unknown effect");
        reg.recordEnactment(id, keccak256("something"), T.EnactmentStatus.Enacted, bytes32(0));
    }

    function test_caseB_appeal_round_NoDecision_keeps_round_one_rejection() public {
        bytes32 id = fileParamChange(7, 42);
        techSigned(id, false);                     // Tech blocks → ALL is No immediately...
        vm.warp(vm.getBlockTimestamp() + 12 hours + 1); // ...but only settles once the veto window closed
        reg.settleRound(id);
        vm.prank(member);
        reg.appeal(id);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);   // round 2: silence everywhere
        reg.settleRound(id);
        assertFinalDecided(id, false);
        assertEq(result(id).sourceRound, 1, "round 2's failure does not erase round 1's decision");
        assertEq(uint8(reg.getRound(id, 2).status), uint8(T.NodeStatus.NoDecision));
    }

    function test_caseB_only_listed_members_may_file_and_charter_can_revoke_for_new_filings() public {
        T.IssueInput memory i;
        i.policyId = pB; i.mode = T.AcceptanceMode.STANDING_ACCEPTANCE; i.acceptanceId = acceptance;
        i.subject = T.Subject({chainId: block.chainid, target: governance, id: 1, dataHash: bytes32(0)});
        i.question = Q_PARAM;
        vm.prank(rando);
        vm.expectRevert("ACDF: filer not accepted");
        reg.file(i);
        bytes32 live = fileParamChange(1, 1);
        vm.prank(governance);
        reg.revokeStandingAcceptance(acceptance);
        vm.prank(member);
        vm.expectRevert("ACDF: acceptance unavailable");
        reg.file(i);
        assertEq(uint8(reg.getIssue(live).state), uint8(T.ProcedureState.Deciding), "in-flight issue unaffected");
    }
}
