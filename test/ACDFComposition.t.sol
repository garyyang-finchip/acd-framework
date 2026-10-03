// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";

/// Test group 3 — body composition: ALL / ANY / K-of-M / VETO, four-valued semantics,
/// authorized-submitter bodies, and policy-graph validation.
contract ACDFCompositionTest is ACDFBase {
    address submitter = address(0x5AB);

    // Tech = members[0..2], Econ = members[2..4] (member 2 sits in both chambers), Screening = members[3..4]
    function chamber(uint256 start, uint256 n, uint32 k, uint64 window) internal view returns (T.BodySpec memory b) {
        b.kind = T.BodyKind.ROSTER_KOFN;
        b.acceptance = T.Acceptance.ON_CHAIN_TALLY;
        b.members = new address[](n);
        for (uint256 i = 0; i < n; i++) b.members[i] = members[start + i];
        b.k = k;
        b.window = window;
    }

    function twoChamber(T.Combinator op, uint32 k, bytes32 family) internal returns (bytes32) {
        T.BodySpec[] memory bodies = new T.BodySpec[](2);
        bodies[0] = chamber(0, 3, 2, 1 days);   // Tech 2-of-3
        bodies[1] = chamber(2, 3, 2, 1 days);   // Econ 2-of-3
        T.Node[] memory nodes = new T.Node[](3);
        nodes[0] = combNode(op, k, u32(1, 2));
        nodes[1] = bodyNode(0);
        nodes[2] = bodyNode(1);
        return register(spec(bodies, nodes, family));
    }

    function vetoPolicy(T.VetoSilence silence, bytes32 family) internal returns (bytes32) {
        T.BodySpec[] memory bodies = new T.BodySpec[](3);
        bodies[0] = chamber(3, 2, 1, 12 hours);  // Screening: 1 approve = veto; 2 blocks = explicit clearance
        bodies[1] = chamber(0, 3, 2, 1 days);    // Tech
        bodies[2] = chamber(2, 3, 2, 1 days);    // Econ
        T.Node[] memory nodes = new T.Node[](4);
        nodes[0] = vetoNode(1, 0, silence);
        nodes[1] = combNode(T.Combinator.ALL, 0, u32(2, 3));
        nodes[2] = bodyNode(1);
        nodes[3] = bodyNode(2);
        return register(spec(bodies, nodes, family));
    }

    function techYes(bytes32 id) internal { vote(id, 0, 0, true); vote(id, 0, 1, true); }
    function techNo(bytes32 id)  internal { vote(id, 0, 0, false); vote(id, 0, 1, false); }
    function econYes(bytes32 id) internal { vote(id, 1, 3, true); vote(id, 1, 4, true); }
    function econNo(bytes32 id)  internal { vote(id, 1, 3, false); vote(id, 1, 4, false); }

    function root(bytes32 id) internal view returns (T.NodeStatus st, T.Reason rs) {
        (st, rs,) = reg.nodeStatus(id, reg.getIssue(id).roundCount, 0);
    }

    // ---------------------------------------------------------------- ALL

    function test_ALL_both_yes_is_yes_and_decided_at_the_later_chamber() public {
        bytes32 p = twoChamber(T.Combinator.ALL, 0, keccak256("all"));
        bytes32 id = fileAsConsumer(p, 1);
        techYes(id);
        (T.NodeStatus st,) = root(id);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "one chamber is not enough");
        vm.warp(vm.getBlockTimestamp() + 3600);
        uint256 later = vm.getBlockTimestamp();
        econYes(id);
        reg.settleRound(id);
        assertFinalDecided(id, true);
        assertEq(result(id).decidedAt, later);
    }

    function test_ALL_any_no_decides_no_without_waiting() public {
        bytes32 p = twoChamber(T.Combinator.ALL, 0, keccak256("all"));
        bytes32 id = fileAsConsumer(p, 1);
        techNo(id);
        reg.settleRound(id); // Econ still pending: a required approval has already been refused
        assertFinalDecided(id, false);
        (T.NodeStatus econ,,) = reg.bodyStatus(id, 1, 1);
        assertEq(uint8(econ), uint8(T.NodeStatus.Pending), "Econ's own status is untouched");
    }

    function test_ALL_yes_plus_NoDecision_is_NoDecision_not_rejection_and_keeps_the_reason() public {
        bytes32 p = twoChamber(T.Combinator.ALL, 0, keccak256("all"));
        bytes32 id = fileAsConsumer(p, 1);
        techYes(id);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1); // Econ never reaches quorum
        (T.NodeStatus st, T.Reason rs) = root(id);
        assertEq(uint8(st), uint8(T.NodeStatus.NoDecision));
        assertEq(uint8(rs), uint8(T.Reason.NOT_REACHED), "'required joint approval not formed', not 'rejected'");
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.NOT_REACHED);
        (T.NodeStatus tech,,) = reg.bodyStatus(id, 1, 0);
        assertEq(uint8(tech), uint8(T.NodeStatus.Yes), "Tech's approval remains on record as evidence");
        (T.NodeStatus econ, T.Reason er,) = reg.bodyStatus(id, 1, 1);
        assertEq(uint8(econ), uint8(T.NodeStatus.NoDecision));
        assertEq(uint8(er), uint8(T.Reason.QUORUM_NOT_MET));
    }

    // ---------------------------------------------------------------- ANY

    function test_ANY_one_yes_passes_early_without_waiting_for_the_other_chamber() public {
        bytes32 p = twoChamber(T.Combinator.ANY, 0, keccak256("any"));
        bytes32 id = fileAsConsumer(p, 1);
        econYes(id);
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_ANY_all_no_is_no_and_no_plus_NoDecision_is_NoDecision() public {
        bytes32 p = twoChamber(T.Combinator.ANY, 0, keccak256("any"));
        bytes32 a = fileAsConsumer(p, 1);
        techNo(a);
        (T.NodeStatus st,) = root(a);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "one refusal does not sink ANY");
        econNo(a);
        reg.settleRound(a);
        assertFinalDecided(a, false);

        bytes32 b = fileAsConsumer(p, 2);
        techNo(b);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(b);
        assertFinalNoDecision(b, T.Reason.NOT_REACHED);
    }

    // ---------------------------------------------------------------- K-of-M

    function threeChamber(uint32 k) internal returns (bytes32) {
        T.BodySpec[] memory bodies = new T.BodySpec[](3);
        bodies[0] = chamber(0, 1, 1, 1 days);   // single-member chambers: one ballot decides each
        bodies[1] = chamber(2, 1, 1, 1 days);
        bodies[2] = chamber(4, 1, 1, 1 days);
        T.Node[] memory nodes = new T.Node[](4);
        nodes[0] = combNode(T.Combinator.KOFM, k, u32(1, 2, 3));
        nodes[1] = bodyNode(0);
        nodes[2] = bodyNode(1);
        nodes[3] = bodyNode(2);
        return register(spec(bodies, nodes, keccak256(abi.encode("kofm", k))));
    }

    function test_KOFM_2of3_chambers() public {
        bytes32 p = threeChamber(2);
        bytes32 a = fileAsConsumer(p, 1);
        vote(a, 0, 0, true);
        (T.NodeStatus st,) = root(a);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending));
        vote(a, 1, 2, true);
        reg.settleRound(a);
        assertFinalDecided(a, true);

        bytes32 b = fileAsConsumer(p, 2);
        vote(b, 0, 0, true); vote(b, 1, 2, false);
        (st,) = root(b);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "1 yes 1 no 1 pending");
        vote(b, 2, 4, false); // 2 refusals = M-K+1
        reg.settleRound(b);
        assertFinalDecided(b, false);

        bytes32 c = fileAsConsumer(p, 3);
        vote(c, 0, 0, true); vote(c, 1, 2, false);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(c);
        assertFinalNoDecision(c, T.Reason.NOT_REACHED);
    }

    // ---------------------------------------------------------------- VETO / PASS_THROUGH

    function test_VETO_pass_through_cannot_settle_before_the_veto_window_closes() public {
        bytes32 p = vetoPolicy(T.VetoSilence.PASS_THROUGH, keccak256("veto.pt"));
        bytes32 id = fileAsConsumer(p, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vote(id, 1, 0, true); vote(id, 1, 1, true);   // Tech yes
        vote(id, 2, 3, true); vote(id, 2, 4, true);   // Econ yes
        (T.NodeStatus st,) = root(id);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "11 hours of veto right remain");
        vm.expectRevert("ACDF: pending");
        reg.settleRound(id);
        vm.warp(vm.getBlockTimestamp() + 11 hours);   // exactly at vetoClose: still open (<=)
        vm.expectRevert("ACDF: pending");
        reg.settleRound(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        reg.settleRound(id);
        assertFinalDecided(id, true);
        assertEq(result(id).decidedAt, vm.getBlockTimestamp() - 1, "determined when the veto window closed");
    }

    function test_VETO_exercised_inside_the_window_decides_no_with_reason_VETOED() public {
        bytes32 p = vetoPolicy(T.VetoSilence.PASS_THROUGH, keccak256("veto.pt"));
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 1, 0, true); vote(id, 1, 1, true);
        vote(id, 2, 3, true); vote(id, 2, 4, true);
        vm.warp(vm.getBlockTimestamp() + 11 hours);
        vote(id, 0, 3, true); // one Screening approve = veto
        reg.settleRound(id);
        assertFinalDecided(id, false);
        assertEq(uint8(result(id).reason), uint8(T.Reason.VETOED));
    }

    function test_VETO_result_type_does_not_depend_on_settlement_order() public {
        // chambers never vote; veto cast at hour 11; nobody settles for two days
        bytes32 p = vetoPolicy(T.VetoSilence.PASS_THROUGH, keccak256("veto.pt"));
        bytes32 a = fileAsConsumer(p, 1);
        vm.warp(vm.getBlockTimestamp() + 11 hours);
        vote(a, 0, 3, true);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        reg.settleRound(a);
        assertFinalDecided(a, false);
        assertEq(uint8(result(a).reason), uint8(T.Reason.VETOED));

        // same silence from the chambers, no veto: NoDecision, never "rejected"
        bytes32 b = fileAsConsumer(p, 2);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        reg.settleRound(b);
        assertFinalNoDecision(b, T.Reason.NOT_REACHED);
    }

    function test_VETO_explicit_clearance_lets_the_target_pass_early() public {
        bytes32 p = vetoPolicy(T.VetoSilence.PASS_THROUGH, keccak256("veto.pt"));
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 1, 0, true); vote(id, 1, 1, true);
        vote(id, 2, 3, true); vote(id, 2, 4, true);
        vote(id, 0, 3, false); vote(id, 0, 4, false); // both screeners block the veto = clearance; irrevocable
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_VETO_late_veto_after_window_is_rejected_and_target_passes() public {
        bytes32 p = vetoPolicy(T.VetoSilence.PASS_THROUGH, keccak256("veto.pt"));
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 1, 0, true); vote(id, 1, 1, true);
        vote(id, 2, 3, true); vote(id, 2, 4, true);
        vm.warp(vm.getBlockTimestamp() + 12 hours + 1);
        vm.prank(members[3]);
        vm.expectRevert("ACDF: body window closed");
        reg.castBallot(id, 0, true);
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    // ---------------------------------------------------------------- VETO / REQUIRE_CLEARANCE

    function test_VETO_require_clearance_silence_is_NoDecision_NO_CLEARANCE() public {
        bytes32 p = vetoPolicy(T.VetoSilence.REQUIRE_CLEARANCE, keccak256("veto.rc"));
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 1, 0, true); vote(id, 1, 1, true);
        vote(id, 2, 3, true); vote(id, 2, 4, true);
        vm.warp(vm.getBlockTimestamp() + 12 hours + 1);
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.NO_CLEARANCE);
    }

    function test_VETO_require_clearance_explicit_clearance_and_veto() public {
        bytes32 p = vetoPolicy(T.VetoSilence.REQUIRE_CLEARANCE, keccak256("veto.rc"));
        bytes32 a = fileAsConsumer(p, 1);
        vote(a, 1, 0, true); vote(a, 1, 1, true);
        vote(a, 2, 3, true); vote(a, 2, 4, true);
        vote(a, 0, 3, false); vote(a, 0, 4, false);
        reg.settleRound(a);
        assertFinalDecided(a, true);

        bytes32 b = fileAsConsumer(p, 2);
        vote(b, 0, 4, true);
        reg.settleRound(b);
        assertFinalDecided(b, false);
        assertEq(uint8(result(b).reason), uint8(T.Reason.VETOED));
    }

    // ---------------------------------------------------------------- authorized submitter bodies

    function submitterPolicy() internal returns (bytes32) {
        T.BodySpec[] memory bodies = new T.BodySpec[](2);
        bodies[0] = chamber(0, 3, 2, 1 days);
        bodies[1] = submitterBody(submitter, 1 days);
        T.Node[] memory nodes = new T.Node[](3);
        nodes[0] = combNode(T.Combinator.ALL, 0, u32(1, 2));
        nodes[1] = bodyNode(0);
        nodes[2] = bodyNode(1);
        return register(spec(bodies, nodes, keccak256("submitter")));
    }

    function test_submitter_body_report_is_accepted_only_from_the_pinned_submitter() public {
        bytes32 p = submitterPolicy();
        bytes32 id = fileAsConsumer(p, 1);
        vm.prank(rando);
        vm.expectRevert("ACDF: not the submitter");
        reg.submitBodyResult(id, 1, T.NodeStatus.Yes);
        vm.prank(submitter);
        vm.expectRevert("ACDF: status required");
        reg.submitBodyResult(id, 1, T.NodeStatus.Pending);
        vm.prank(submitter);
        vm.expectRevert("ACDF: body not on-chain tally");
        reg.castBallot(id, 1, true);
        vm.prank(submitter);
        reg.submitBodyResult(id, 1, T.NodeStatus.Yes);
        vm.prank(submitter);
        vm.expectRevert("ACDF: already submitted");
        reg.submitBodyResult(id, 1, T.NodeStatus.No);
        techYes(id);
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_submitter_silence_is_NoDecision_SUBMITTER_SILENT_and_late_report_rejected() public {
        bytes32 p = submitterPolicy();
        bytes32 id = fileAsConsumer(p, 1);
        techYes(id);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(submitter);
        vm.expectRevert("ACDF: body window closed");
        reg.submitBodyResult(id, 1, T.NodeStatus.Yes);
        (T.NodeStatus st, T.Reason rs,) = reg.bodyStatus(id, 1, 1);
        assertEq(uint8(st), uint8(T.NodeStatus.NoDecision));
        assertEq(uint8(rs), uint8(T.Reason.SUBMITTER_SILENT));
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.NOT_REACHED);
    }

    function test_submitter_may_report_NoDecision_explicitly() public {
        bytes32 p = submitterPolicy();
        bytes32 id = fileAsConsumer(p, 1);
        techYes(id);
        vm.prank(submitter);
        reg.submitBodyResult(id, 1, T.NodeStatus.NoDecision);
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.NOT_REACHED);
    }

    // ---------------------------------------------------------------- policy graph validation

    function baseBodies() internal view returns (T.BodySpec[] memory bodies) {
        bodies = new T.BodySpec[](2);
        bodies[0] = chamber(0, 3, 2, 1 days);
        bodies[1] = chamber(2, 3, 2, 1 days);
    }

    function expectRegisterRevert(T.PolicySpec memory s, string memory err) internal {
        vm.prank(authority);
        vm.expectRevert(bytes(err));
        pol.registerPolicy(s);
    }

    function test_duplicate_child_rejected() public {
        T.Node[] memory nodes = new T.Node[](3);
        nodes[0] = combNode(T.Combinator.ALL, 0, u32(1, 1));
        nodes[1] = bodyNode(0);
        nodes[2] = bodyNode(1);
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g1")), "ACDF: duplicate child");
    }

    function test_backward_or_self_edge_rejected_as_cycle() public {
        T.Node[] memory nodes = new T.Node[](3);
        nodes[0] = combNode(T.Combinator.ALL, 0, u32(1, 2));
        nodes[1] = bodyNode(0);
        nodes[2] = combNode(T.Combinator.ANY, 0, u32(1, 0)); // points back to 1 and to the root
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g2")), "ACDF: child index");
    }

    function test_unreferenced_node_and_doubly_referenced_node_rejected() public {
        T.Node[] memory nodes = new T.Node[](3);
        nodes[0] = bodyNode(0);          // root uses body 0 only
        nodes[1] = bodyNode(1);          // never referenced
        nodes[2] = bodyNode(1);
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g3")), "ACDF: node not in tree");

        T.Node[] memory nodes2 = new T.Node[](4);
        nodes2[0] = combNode(T.Combinator.ALL, 0, u32(1, 2));
        nodes2[1] = combNode(T.Combinator.ANY, 0, u32(3, 2)); // node 2 referenced twice
        nodes2[2] = bodyNode(0);
        nodes2[3] = bodyNode(1);
        expectRegisterRevert(spec(baseBodies(), nodes2, keccak256("g4")), "ACDF: node not in tree");
    }

    function test_empty_graph_bad_body_index_and_bad_k_rejected() public {
        T.Node[] memory none = new T.Node[](0);
        expectRegisterRevert(spec(baseBodies(), none, keccak256("g5")), "ACDF: nodes out of range");

        T.Node[] memory nodes = new T.Node[](1);
        nodes[0] = bodyNode(7);
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g6")), "ACDF: body index");

        T.Node[] memory nodes2 = new T.Node[](3);
        nodes2[0] = combNode(T.Combinator.KOFM, 3, u32(1, 2));
        nodes2[1] = bodyNode(0);
        nodes2[2] = bodyNode(1);
        expectRegisterRevert(spec(baseBodies(), nodes2, keccak256("g7")), "ACDF: bad node k");

        T.Node[] memory nodes3 = new T.Node[](1);
        nodes3[0] = combNode(T.Combinator.ALL, 0, new uint32[](0));
        expectRegisterRevert(spec(baseBodies(), nodes3, keccak256("g8")), "ACDF: no children");
    }

    function test_veto_target_must_be_a_later_node_and_veto_body_must_exist() public {
        T.Node[] memory nodes = new T.Node[](2);
        nodes[0] = vetoNode(0, 1, T.VetoSilence.PASS_THROUGH); // target == self
        nodes[1] = bodyNode(0);
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g9")), "ACDF: veto target");

        nodes[0] = vetoNode(1, 9, T.VetoSilence.PASS_THROUGH);
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g10")), "ACDF: veto body index");

        nodes[0] = vetoNode(1, 1, T.VetoSilence.PASS_THROUGH);
        nodes[0].children = u32(1, 1);
        expectRegisterRevert(spec(baseBodies(), nodes, keccak256("g11")), "ACDF: veto node has children");
    }

    function test_body_kind_acceptance_mismatch_rejected() public {
        T.BodySpec[] memory bodies = baseBodies();
        bodies[0].acceptance = T.Acceptance.AUTHORIZED_SUBMITTER; // a roster cannot use submitter acceptance
        T.Node[] memory nodes = new T.Node[](3);
        nodes[0] = combNode(T.Combinator.ALL, 0, u32(1, 2));
        nodes[1] = bodyNode(0); nodes[2] = bodyNode(1);
        expectRegisterRevert(spec(bodies, nodes, keccak256("g12")), "ACDF: roster acceptance");

        bodies = baseBodies();
        bodies[1] = submitterBody(submitter, 1 days);
        bodies[1].acceptance = T.Acceptance.ON_CHAIN_TALLY;
        expectRegisterRevert(spec(bodies, nodes, keccak256("g13")), "ACDF: submitter acceptance");

        bodies[1] = submitterBody(submitter, 1 days);
        bodies[1].members = new address[](2);
        bodies[1].members[0] = submitter; bodies[1].members[1] = rando;
        expectRegisterRevert(spec(bodies, nodes, keccak256("g14")), "ACDF: submitter required");
    }

    function test_max_total_duration_must_cover_rounds_and_appeals() public {
        T.PolicySpec memory s = minimalSpec(3, 2, 1 days);
        s.maxAppeals = 2; s.appealWindow = 2 days; s.appealable = 3;
        s.maxTotalDuration = 3 days + 4 days - 1; // (2+1)*1d + 2*2d = 7d needed
        expectRegisterRevert(s, "ACDF: maxTotalDuration too short");
        s.maxTotalDuration = 7 days;
        register(s);

        s = minimalSpec(3, 2, 1 days);
        s.maxAppeals = 1; s.appealWindow = 0; s.appealable = 1;
        expectRegisterRevert(s, "ACDF: zero appeal window");
        s.appealWindow = 1 days; s.appealable = 0;
        expectRegisterRevert(s, "ACDF: appealable mask");
    }
}
