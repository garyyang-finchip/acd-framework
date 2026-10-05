// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";

/// Test group 4 — rounds, appeals, finality and timeouts.
contract ACDFRoundsTest is ACDFBase {
    bytes32 pDecidedOnly;  // 2-of-3, 1 appeal, 2-day appeal window, only Decided appealable
    bytes32 pBoth;         // same, both outcome types appealable
    bytes32 pStanding;     // appeal standing restricted to consumer or filer
    bytes32 pSigned;       // SIGNED_BALLOTS body with one appeal

    function appealSpec(uint8 appealable, bytes32 family) internal view returns (T.PolicySpec memory s) {
        s = minimalSpec(3, 2, 1 days);
        s.family = family;
        s.maxAppeals = 1;
        s.appealWindow = 2 days;
        s.appealable = appealable;
        s.maxTotalDuration = 10 days;
    }

    function setUp() public override {
        super.setUp();
        pDecidedOnly = register(appealSpec(1, keccak256("appeal.decided")));
        pBoth = register(appealSpec(3, keccak256("appeal.both")));
        T.PolicySpec memory s = appealSpec(3, keccak256("appeal.standing"));
        s.appealStanding = T.AppealStanding.CONSUMER_OR_FILER;
        pStanding = register(s);
        s = appealSpec(3, keccak256("appeal.signed"));
        s.bodies[0].acceptance = T.Acceptance.SIGNED_BALLOTS;
        pSigned = register(s);
    }

    function decideYes(bytes32 id) internal { vote(id, 0, 0, true); vote(id, 0, 1, true); }
    function decideNo(bytes32 id)  internal { vote(id, 0, 0, false); vote(id, 0, 1, false); }

    // ---------------------------------------------------------------- provisional → appeal → final

    function test_decided_round_becomes_provisional_then_final_after_the_window() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        decideYes(id);
        uint256 at = vm.getBlockTimestamp();
        reg.settleRound(id);
        T.Result memory r = result(id);
        assertEq(uint8(r.state), uint8(T.ProcedureState.Provisional));
        assertEq(uint8(r.outcomeType), uint8(T.OutcomeType.None), "no adopted outcome before Final");
        T.RoundState memory rs = reg.getRound(id, 1);
        assertTrue(rs.settled);
        assertEq(uint8(rs.status), uint8(T.NodeStatus.Yes));
        assertEq(rs.appealOpenUntil, at + 2 days);

        vm.expectRevert("ACDF: appeal window open");
        reg.finalize(id);
        vm.warp(at + 2 days + 1);
        vm.expectRevert("ACDF: appeal window closed");
        reg.appeal(id);
        reg.finalize(id);
        assertFinalDecided(id, true);
        assertEq(result(id).sourceRound, 1);
    }

    function test_appeal_opens_round_two_whose_decision_supersedes_round_one() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        decideYes(id);
        reg.settleRound(id);
        vm.prank(rando);
        reg.appeal(id); // ANYONE standing
        T.Issue memory it = reg.getIssue(id);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Deciding));
        assertEq(it.roundCount, 2);
        assertFalse(reg.hasVoted(id, 2, 0, members[0]), "round 2 starts with fresh ballots");
        decideNo(id);
        reg.settleRound(id); // appeals exhausted: straight to Final, no second provisional
        assertFinalDecided(id, false);
        assertEq(result(id).sourceRound, 2);
        assertEq(result(id).roundCount, 2);
        T.RoundState memory r1 = reg.getRound(id, 1);
        assertEq(uint8(r1.status), uint8(T.NodeStatus.Yes), "round 1 stays on record");
    }

    function test_appeals_exhausted_nothing_can_reopen_a_final_issue() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        decideYes(id);
        reg.settleRound(id);
        reg.appeal(id);
        decideYes(id);
        reg.settleRound(id);
        assertFinalDecided(id, true);

        vm.expectRevert("ACDF: not provisional");
        reg.appeal(id);
        vm.expectRevert("ACDF: not deciding");
        reg.settleRound(id);
        vm.expectRevert("ACDF: not provisional");
        reg.finalize(id);
        vm.expectRevert("ACDF: not open");
        reg.enforceHardDeadline(id);
        vm.prank(members[2]);
        vm.expectRevert("ACDF: not deciding");
        reg.castBallot(id, 1, 0, false);
        // Final is terminal: the adopted result cannot change afterwards
        T.Result memory before = result(id);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        T.Result memory after_ = result(id);
        assertEq(uint8(after_.state), uint8(before.state));
        assertEq(after_.outcomeYes, before.outcomeYes);
        assertEq(after_.sourceRound, before.sourceRound);
    }

    // ---------------------------------------------------------------- NoDecision and appeals

    function test_NoDecision_not_appealable_goes_straight_to_final() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.QUORUM_NOT_MET);
        assertEq(reg.getRound(id, 1).appealOpenUntil, 0);
    }

    function test_NoDecision_appealable_opens_the_committed_window_first() public {
        bytes32 id = fileAsConsumer(pBoth, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(id);
        assertEq(uint8(result(id).state), uint8(T.ProcedureState.Provisional), "a NoDecision cannot skip a promised window");
        reg.appeal(id);
        decideYes(id);
        reg.settleRound(id);
        assertFinalDecided(id, true);
        assertEq(result(id).sourceRound, 2);
    }

    function test_appeal_round_NoDecision_keeps_the_previous_substantive_decision() public {
        bytes32 id = fileAsConsumer(pBoth, 1);
        decideNo(id);                       // round 1: explicit rejection
        reg.settleRound(id);
        reg.appeal(id);                     // loser appeals
        vm.warp(vm.getBlockTimestamp() + 1 days + 1); // round 2: nobody shows up
        reg.settleRound(id);
        // appeals exhausted → Final; the adopted decision is round 1's rejection
        assertFinalDecided(id, false);
        T.Result memory r = result(id);
        assertEq(r.sourceRound, 1, "adopted from round 1");
        assertEq(r.roundCount, 2, "but two rounds were run");
        T.RoundState memory r2 = reg.getRound(id, 2);
        assertEq(uint8(r2.status), uint8(T.NodeStatus.NoDecision), "round 2's NoDecision is recorded, not hidden");
        assertEq(uint8(r2.reason), uint8(T.Reason.QUORUM_NOT_MET));
    }

    function test_no_substantive_decision_in_any_round_is_final_NoDecision() public {
        bytes32 id = fileAsConsumer(pBoth, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(id);
        reg.appeal(id);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(id);
        assertFinalNoDecision(id, T.Reason.QUORUM_NOT_MET);
        assertEq(result(id).sourceRound, 2);
    }

    // ---------------------------------------------------------------- standing

    function test_appeal_standing_consumer_or_filer() public {
        bytes32 id = fileAsConsumer(pStanding, 1);
        decideYes(id);
        reg.settleRound(id);
        vm.prank(rando);
        vm.expectRevert("ACDF: no standing");
        reg.appeal(id);
        vm.prank(consumer);
        reg.appeal(id);
        assertEq(reg.getIssue(id).roundCount, 2);
    }

    // ---------------------------------------------------------------- timing discipline

    function test_appeal_window_runs_from_the_decision_instant_not_the_settlement_call() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        decideYes(id);
        uint256 at = vm.getBlockTimestamp();
        vm.warp(at + 3 days); // nobody settled for three days: the window has already lapsed
        reg.settleRound(id);
        assertFinalDecided(id, true);
        assertEq(reg.getRound(id, 1).appealOpenUntil, at + 2 days, "window anchored to the decision instant");
    }

    function test_round_deadline_and_hard_deadline_are_recorded_at_admission() public {
        uint256 t0 = vm.getBlockTimestamp();
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        T.RoundState memory r = reg.getRound(id, 1);
        assertEq(r.startedAt, t0);
        assertEq(r.deadline, t0 + 1 days);
        assertEq(reg.getIssue(id).hardDeadline, t0 + 10 days);
    }

    function test_hard_deadline_closes_an_issue_left_open_in_any_non_final_state() public {
        // Deciding, everyone silent for the entire cap
        bytes32 a = fileAsConsumer(pDecidedOnly, 1);
        vm.expectRevert("ACDF: before hard deadline");
        reg.enforceHardDeadline(a);
        vm.warp(vm.getBlockTimestamp() + 10 days + 1);
        reg.enforceHardDeadline(a);
        assertFinalNoDecision(a, T.Reason.QUORUM_NOT_MET);

        // Provisional, nobody finalized: the cap still closes it, adopting the decision
        bytes32 b = fileAsConsumer(pDecidedOnly, 2);
        decideYes(b);
        reg.settleRound(b);
        vm.warp(vm.getBlockTimestamp() + 10 days + 1);
        reg.enforceHardDeadline(b);
        assertFinalDecided(b, true);
    }

    function test_old_round_signed_ballot_cannot_be_replayed_in_a_new_round() public {
        bytes32 id = fileAsConsumer(pSigned, 1);
        address[] memory v = new address[](2); v[0] = members[0]; v[1] = members[1];
        bool[] memory a = new bool[](2); a[0] = true; a[1] = true;
        bytes[] memory s = new bytes[](2);
        s[0] = sign(pk[0], reg.ballotDigest(id, 1, 0, members[0], true));
        s[1] = sign(pk[1], reg.ballotDigest(id, 1, 0, members[1], true));
        reg.submitSignedBallots(id, 0, v, a, s);
        reg.settleRound(id);
        reg.appeal(id);
        assertEq(reg.getIssue(id).roundCount, 2);
        vm.expectRevert("ACDF: bad signature"); // the digest binds the round
        reg.submitSignedBallots(id, 0, v, a, s);
        // fresh round-2 signatures work
        s[0] = sign(pk[0], reg.ballotDigest(id, 2, 0, members[0], false));
        s[1] = sign(pk[1], reg.ballotDigest(id, 2, 0, members[1], false));
        a[0] = false; a[1] = false;
        reg.submitSignedBallots(id, 0, v, a, s);
        reg.settleRound(id);
        assertFinalDecided(id, false);
        assertEq(result(id).sourceRound, 2);
    }

    /// The on-chain ballot names its round, exactly like the signed digest does: a transaction
    /// meant for round 1 that lands after an appeal opened round 2 is refused, never re-counted.
    function test_on_chain_ballot_bound_to_a_settled_round_is_refused_in_the_next_round() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        vote(id, 0, 0, true); vote(id, 0, 1, true); // 2-of-3 decides Yes in round 1
        reg.settleRound(id);
        reg.appeal(id);
        assertEq(reg.getIssue(id).roundCount, 2);
        // member 2's round-1 transaction arrives now
        vm.prank(members[2]);
        vm.expectRevert("ACDF: round mismatch");
        reg.castBallot(id, 1, 0, false);
        // a ballot that names round 2 is a fresh, intended vote
        vm.prank(members[2]);
        reg.castBallot(id, 2, 0, false);
        assertTrue(reg.hasVoted(id, 2, 0, members[2]));
        assertFalse(reg.hasVoted(id, 1, 0, members[2]));
        // a future round cannot be voted into either
        vm.prank(members[0]);
        vm.expectRevert("ACDF: round mismatch");
        reg.castBallot(id, 3, 0, false);
    }

    function test_submitter_report_bound_to_a_settled_round_is_refused_in_the_next_round() public {
        T.PolicySpec memory s = appealSpec(3, keccak256("appeal.submitter"));
        s.bodies[0] = submitterBody(members[0], 1 days);
        bytes32 p = register(s);
        bytes32 id = fileAsConsumer(p, 1);
        vm.prank(members[0]);
        reg.submitBodyResult(id, 1, 0, T.NodeStatus.Yes);
        reg.settleRound(id);
        reg.appeal(id);
        vm.prank(members[0]);
        vm.expectRevert("ACDF: round mismatch");
        reg.submitBodyResult(id, 1, 0, T.NodeStatus.No); // stale round-1 report
        vm.prank(members[0]);
        reg.submitBodyResult(id, 2, 0, T.NodeStatus.No);
        reg.settleRound(id);
        assertFinalDecided(id, false);
        assertEq(result(id).sourceRound, 2);
    }

    function test_round_reads_are_bounds_checked() public {
        bytes32 id = fileAsConsumer(pDecidedOnly, 1);
        vm.expectRevert("ACDF: round index");
        reg.getRound(id, 0);
        vm.expectRevert("ACDF: round index");
        reg.getRound(id, 2);
        vm.expectRevert("ACDF: round index");
        reg.nodeStatus(id, 2, 0);
    }
}
