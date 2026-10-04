// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";
import {IACDFPolicyRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFPolicyRegistry.sol";
import {IACDFRegistry} from "../assets/erc-acdf/contracts/interfaces/IACDFRegistry.sol";

/// Test group 1 — minimal tally (fixed roster, equal weight, K-of-N).
contract ACDFMinimalTest is ACDFBase {

    // ---------------------------------------------------------------- happy paths

    function test_1of1_approve_is_final_decided_yes() public {
        bytes32 p = registerMinimal(1, 1, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, true);
        reg.settleRound(id);
        assertFinalDecided(id, true);
        T.Result memory r = result(id);
        assertEq(r.sourceRound, 1);
        assertEq(r.roundCount, 1);
    }

    function test_1of1_block_is_final_decided_no() public {
        bytes32 p = registerMinimal(1, 1, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, false);
        reg.settleRound(id);
        assertFinalDecided(id, false);
    }

    function test_K1_of_5_single_approval_decides() public {
        bytes32 p = registerMinimal(5, 1, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 3, true);
        (T.NodeStatus st,,) = reg.bodyStatus(id, 1, 0);
        assertEq(uint8(st), uint8(T.NodeStatus.Yes));
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_K1_of_5_needs_all_five_blocks_to_reject() public {
        bytes32 p = registerMinimal(5, 1, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        for (uint256 i = 0; i < 4; i++) vote(id, 0, i, false);
        (T.NodeStatus st,,) = reg.bodyStatus(id, 1, 0);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "4 blocks of 5 do not decide when K=1");
        vote(id, 0, 4, false);
        reg.settleRound(id);
        assertFinalDecided(id, false);
    }

    function test_KN_of_5_single_block_rejects() public {
        bytes32 p = registerMinimal(5, 5, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        for (uint256 i = 0; i < 4; i++) vote(id, 0, i, true);
        (T.NodeStatus st,,) = reg.bodyStatus(id, 1, 0);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending));
        vote(id, 0, 4, false); // N-K+1 = 1 block
        reg.settleRound(id);
        assertFinalDecided(id, false);
    }

    function test_3of5_complementary_thresholds() public {
        bytes32 p = registerMinimal(5, 3, 1 days);
        bytes32 a = fileAsConsumer(p, 1);
        vote(a, 0, 0, true); vote(a, 0, 1, false); vote(a, 0, 2, true);
        (T.NodeStatus st,,) = reg.bodyStatus(a, 1, 0);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "2 yes 1 no is pending");
        vote(a, 0, 3, true);
        reg.settleRound(a);
        assertFinalDecided(a, true);

        bytes32 b = fileAsConsumer(p, 2);
        vote(b, 0, 0, false); vote(b, 0, 1, true); vote(b, 0, 2, false);
        (st,,) = reg.bodyStatus(b, 1, 0);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending));
        vote(b, 0, 3, false); // 3 = N-K+1 blocks
        reg.settleRound(b);
        assertFinalDecided(b, false);
    }

    function test_decision_instant_is_the_deciding_ballot_time() public {
        bytes32 p = registerMinimal(5, 3, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, true);
        vm.warp(vm.getBlockTimestamp() + 100);
        vote(id, 0, 1, true);
        vm.warp(vm.getBlockTimestamp() + 100);
        uint256 deciding = vm.getBlockTimestamp();
        vote(id, 0, 2, true);
        vm.warp(vm.getBlockTimestamp() + 3600);
        reg.settleRound(id);
        assertEq(result(id).decidedAt, deciding);
    }

    // ---------------------------------------------------------------- NoDecision

    function test_deadline_without_threshold_is_NoDecision_not_rejection() public {
        bytes32 p = registerMinimal(5, 3, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, true); vote(id, 0, 1, false);
        vm.expectRevert("ACDF: pending");
        reg.settleRound(id);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.QUORUM_NOT_MET);
        T.Result memory r = result(id);
        assertEq(r.outcomeYes, false);
        assertEq(r.decidedAt, uint64(vm.getBlockTimestamp() - 1), "NoDecision instant is the window close");
    }

    function test_no_ballots_at_all_is_NoDecision() public {
        bytes32 p = registerMinimal(3, 2, 1 hours);
        bytes32 id = fileAsConsumer(p, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.QUORUM_NOT_MET);
    }

    // ---------------------------------------------------------------- ballot discipline

    function test_duplicate_vote_reverts() public {
        bytes32 p = registerMinimal(5, 3, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, true);
        vm.prank(members[0]);
        vm.expectRevert("ACDF: already voted");
        reg.castBallot(id, 0, false); // changing one's mind is not allowed in the minimal profile
    }

    function test_non_member_cannot_vote() public {
        bytes32 p = registerMinimal(3, 2, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vm.prank(members[4]); // exists in the fixture, not in this roster of 3
        vm.expectRevert("ACDF: not a member");
        reg.castBallot(id, 0, true);
        vm.prank(rando);
        vm.expectRevert("ACDF: not a member");
        reg.castBallot(id, 0, true);
    }

    function test_late_vote_reverts() public {
        bytes32 p = registerMinimal(3, 2, 1 hours);
        bytes32 id = fileAsConsumer(p, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(members[0]);
        vm.expectRevert("ACDF: body window closed");
        reg.castBallot(id, 0, true);
    }

    function test_vote_at_exact_window_close_is_accepted() public {
        bytes32 p = registerMinimal(3, 1, 1 hours);
        bytes32 id = fileAsConsumer(p, 1);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vote(id, 0, 0, true);
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_vote_after_body_decided_reverts() public {
        bytes32 p = registerMinimal(5, 2, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, true); vote(id, 0, 1, true);
        vm.prank(members[2]);
        vm.expectRevert("ACDF: body decided");
        reg.castBallot(id, 0, false);
    }

    function test_vote_before_admission_or_after_final_reverts() public {
        bytes32 p = registerMinimal(1, 1, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        vote(id, 0, 0, true);
        reg.settleRound(id);
        vm.prank(members[0]);
        vm.expectRevert("ACDF: not deciding");
        reg.castBallot(id, 0, true);
    }

    function test_signed_submission_rejected_for_on_chain_body_and_vice_versa() public {
        bytes32 p = registerMinimal(3, 2, 1 days);
        bytes32 id = fileAsConsumer(p, 1);
        address[] memory v = new address[](1); v[0] = members[0];
        bool[] memory a = new bool[](1); a[0] = true;
        bytes[] memory s = new bytes[](1); s[0] = sign(pk[0], reg.ballotDigest(id, 1, 0, members[0], true));
        vm.expectRevert("ACDF: body not signed ballots");
        reg.submitSignedBallots(id, 0, v, a, s);

        // and a roster body never accepts an authorized-submitter report
        vm.prank(members[0]);
        vm.expectRevert("ACDF: body not submitter");
        reg.submitBodyResult(id, 0, T.NodeStatus.Yes);
    }

    // ---------------------------------------------------------------- policy validation

    function test_duplicate_member_rejected() public {
        T.PolicySpec memory s = minimalSpec(3, 2, 1 days);
        s.bodies[0].members[2] = s.bodies[0].members[0];
        vm.prank(authority);
        vm.expectRevert("ACDF: duplicate member");
        pol.registerPolicy(s);
    }

    function test_zero_member_rejected() public {
        T.PolicySpec memory s = minimalSpec(3, 2, 1 days);
        s.bodies[0].members[1] = address(0);
        vm.prank(authority);
        vm.expectRevert("ACDF: zero member");
        pol.registerPolicy(s);
    }

    function test_illegal_thresholds_rejected() public {
        T.PolicySpec memory s = minimalSpec(3, 0, 1 days);
        vm.prank(authority);
        vm.expectRevert("ACDF: bad k");
        pol.registerPolicy(s);
        s = minimalSpec(3, 4, 1 days);
        vm.prank(authority);
        vm.expectRevert("ACDF: bad k");
        pol.registerPolicy(s);
    }

    function test_empty_roster_and_zero_window_rejected() public {
        T.PolicySpec memory s = minimalSpec(1, 1, 1 days);
        s.bodies[0].members = new address[](0);
        vm.prank(authority);
        vm.expectRevert("ACDF: empty roster");
        pol.registerPolicy(s);
        s = minimalSpec(1, 1, 0);
        vm.prank(authority);
        vm.expectRevert("ACDF: zero window");
        pol.registerPolicy(s);
    }

    function test_policy_id_is_the_hash_of_every_execution_parameter() public {
        T.PolicySpec memory a = minimalSpec(5, 3, 1 days);
        T.PolicySpec memory b = minimalSpec(5, 3, 1 days);
        assertEq(pol.policyIdOf(a), pol.policyIdOf(b));
        b.bodies[0].k = 2;                       // "JSON says 3-of-5, contract runs K=2" is impossible:
        assertTrue(pol.policyIdOf(a) != pol.policyIdOf(b)); // K is inside the hashed object
        b = minimalSpec(5, 3, 1 days);
        b.bodies[0].window = 1 days + 1;
        assertTrue(pol.policyIdOf(a) != pol.policyIdOf(b));
        b = minimalSpec(5, 3, 1 days);
        b.descriptorHash = keccak256("other descriptor");
        assertTrue(pol.policyIdOf(a) != pol.policyIdOf(b));
    }

    function test_registered_policy_reads_back_the_executed_parameters() public {
        bytes32 p = registerMinimal(5, 3, 1 days);
        T.BodySpec memory b = pol.bodyOf(p, 0);
        assertEq(b.k, 3);
        assertEq(b.members.length, 5);
        assertEq(b.window, 1 days);
        assertEq(pol.roundDurationOf(p), 1 days);
        assertEq(pol.nodeCount(p), 1);
        assertTrue(pol.policyExists(p));
        vm.prank(authority);
        vm.expectRevert("ACDF: policy exists");
        pol.registerPolicy(minimalSpec(5, 3, 1 days));
    }

    function test_family_versioning() public {
        T.PolicySpec memory v1 = minimalSpec(5, 3, 1 days);
        bytes32 id1 = register(v1);
        (bytes32 latest, uint32 ver) = pol.familyLatest(v1.family);
        assertEq(latest, id1); assertEq(ver, 1);

        T.PolicySpec memory v2 = minimalSpec(5, 4, 1 days);
        v2.family = v1.family; v2.version = 2; v2.previous = id1;
        vm.prank(rando);
        vm.expectRevert("ACDF: not family authority");
        pol.registerPolicy(v2);

        v2.previous = bytes32(uint256(1));
        vm.prank(authority);
        vm.expectRevert("ACDF: previous != latest");
        pol.registerPolicy(v2);

        v2.previous = id1; v2.version = 1;
        vm.prank(authority);
        vm.expectRevert("ACDF: version not increasing");
        pol.registerPolicy(v2);

        v2.version = 2;
        bytes32 id2 = register(v2);
        (latest, ver) = pol.familyLatest(v1.family);
        assertEq(latest, id2); assertEq(ver, 2);
        // v1 still exists and is still bindable: publishing v2 changes nothing for v1 issues
        assertTrue(pol.policyExists(id1));
        bytes32 issue = fileAsConsumer(id1, 1);
        assertEq(result(issue).policyId, id1);
    }

    function test_first_version_must_not_cite_previous() public {
        T.PolicySpec memory s = minimalSpec(5, 3, 1 days);
        s.previous = keccak256("ghost");
        vm.prank(authority);
        vm.expectRevert("ACDF: first version has no previous");
        pol.registerPolicy(s);
    }

    function test_erc165_interface_ids() public view {
        assertTrue(pol.supportsInterface(0x01ffc9a7));
        assertTrue(pol.supportsInterface(type(IACDFPolicyRegistry).interfaceId));
        assertFalse(pol.supportsInterface(0xffffffff));
        assertTrue(reg.supportsInterface(0x01ffc9a7));
        assertTrue(reg.supportsInterface(type(IACDFRegistry).interfaceId));
        assertFalse(reg.supportsInterface(0xffffffff));
    }

    function test_clock_mode() public view {
        assertEq(reg.CLOCK_MODE(), "mode=timestamp");
        assertEq(uint256(reg.clock()), vm.getBlockTimestamp());
    }
}
