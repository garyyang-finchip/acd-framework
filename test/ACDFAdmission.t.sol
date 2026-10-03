// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";

/// Test group 2 — acceptance modes, admission, freezing, withdrawal, obligation uniqueness.
contract ACDFAdmissionTest is ACDFBase {
    bytes32 p;         // minimal 2-of-3, 1 day, no POST_ACK
    bytes32 pAck;      // same body, POST_ACK enabled (ackWindow 1h), advisory allowed
    bytes32 pAckStrict;// POST_ACK enabled, advisory NOT allowed

    function setUp() public override {
        super.setUp();
        p = registerMinimal(3, 2, 1 days);
        T.PolicySpec memory s = minimalSpec(3, 2, 1 days);
        s.family = keccak256("family.ack"); s.ackWindow = 1 hours; s.allowAdvisory = true;
        pAck = register(s);
        s = minimalSpec(3, 2, 1 days);
        s.family = keccak256("family.ack.strict"); s.ackWindow = 1 hours; s.allowAdvisory = false;
        pAckStrict = register(s);
    }

    // ---------------------------------------------------------------- CONSUMER_FILED

    function test_consumer_filed_admits_atomically_as_binding() public {
        bytes32 id = fileAsConsumer(p, 1);
        T.Issue memory it = reg.getIssue(id);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Deciding));
        assertEq(uint8(it.effectClass), uint8(T.EffectClass.Binding));
        assertEq(it.consumer, consumer);
        assertEq(it.filer, consumer);
        assertEq(it.hardDeadline, it.admittedAt + 30 days);
        assertEq(it.roundCount, 1);
        assertEq(reg.activeIssueOf(consumer, it.obligationKey), id);
    }

    function test_unauthorized_binding_consumer_mismatch_reverts() public {
        T.IssueInput memory i = consumerInput(p, 1, 0);
        vm.prank(rando); // claims to bind `consumer`
        vm.expectRevert("ACDF: consumer must file");
        reg.file(i);
    }

    function test_binding_requires_effects() public {
        T.IssueInput memory i = consumerInput(p, 1, 0);
        i.effectNo = bytes32(0);
        vm.prank(consumer);
        vm.expectRevert("ACDF: effects required");
        reg.file(i);
    }

    function test_unknown_policy_reverts() public {
        T.IssueInput memory i = consumerInput(keccak256("nope"), 1, 0);
        vm.prank(consumer);
        vm.expectRevert("ACDF: unknown policy");
        reg.file(i);
    }

    function test_consumer_deadline_must_cover_the_whole_procedure() public {
        // policy maxTotalDuration = 30 days; a deadline 10 days out cannot host it
        T.IssueInput memory i = consumerInput(p, 1, uint64(vm.getBlockTimestamp() + 10 days));
        vm.prank(consumer);
        vm.expectRevert("ACDF: insufficient window");
        reg.file(i);
        // exactly 30 days is enough (<=)
        i.consumerDeadline = uint64(vm.getBlockTimestamp() + 30 days);
        vm.prank(consumer);
        bytes32 id = reg.file(i);
        assertEq(reg.getIssue(id).consumerDeadline, i.consumerDeadline);
    }

    // ---------------------------------------------------------------- obligation uniqueness

    function test_same_obligation_cannot_be_filed_twice_while_open() public {
        bytes32 id1 = fileAsConsumer(p, 1);
        vm.prank(consumer);
        vm.expectRevert("ACDF: obligation active");
        reg.file(consumerInput(p, 1, 0));
        // a different subject id is a different obligation
        bytes32 id2 = fileAsConsumer(p, 2);
        assertTrue(id1 != id2);
        // the same subject bound by a different consumer is a different obligation (one fact, many issues)
        T.IssueInput memory i = consumerInput(p, 1, 0);
        i.consumer = rando;
        vm.prank(rando);
        reg.file(i);
    }

    function test_same_obligation_may_be_refiled_once_the_previous_issue_is_terminal() public {
        bytes32 id1 = fileAsConsumer(p, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(id1);               // NoDecision, Final
        bytes32 id2 = fileAsConsumer(p, 1); // registry allows; the consumer's own rules decide whether to re-file
        assertTrue(id2 != id1);
        assertEq(reg.activeIssueOf(consumer, reg.getIssue(id2).obligationKey), id2);
    }

    // ---------------------------------------------------------------- STANDING_ACCEPTANCE

    function standing(address[] memory filers, bytes32 policyId) internal returns (bytes32 accId) {
        T.StandingAcceptanceInput memory a;
        a.policyId = policyId;
        a.subjectTarget = address(0x7A5);
        a.question = Q;
        a.filers = filers;
        a.effectYes = keccak256("committed.yes");
        a.effectNo = keccak256("committed.no");
        a.disposition = keccak256("committed.disposition");
        a.validUntil = 0;
        vm.prank(consumer);
        accId = reg.registerStandingAcceptance(a);
    }

    function standingInput(bytes32 accId, bytes32 policyId, uint256 id) internal view returns (T.IssueInput memory i) {
        i.policyId = policyId;
        i.mode = T.AcceptanceMode.STANDING_ACCEPTANCE;
        i.acceptanceId = accId;
        i.subject = subject(id);
        i.question = Q;
        // the filer "proposes" effects of its own: they must be ignored
        i.effectYes = keccak256("filer.yes");
        i.effectNo = keccak256("filer.no");
        i.disposition = keccak256("filer.disposition");
    }

    function test_standing_acceptance_binds_consumer_and_freezes_its_committed_parameters() public {
        address[] memory filers = new address[](1); filers[0] = filer;
        bytes32 acc = standing(filers, p);
        vm.prank(filer);
        bytes32 id = reg.file(standingInput(acc, p, 1));
        T.Issue memory it = reg.getIssue(id);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Deciding));
        assertEq(it.consumer, consumer);
        assertEq(it.filer, filer);
        assertEq(it.effectYes, keccak256("committed.yes"), "filer cannot vary the consumer's effects");
        assertEq(it.effectNo, keccak256("committed.no"));
        assertEq(it.disposition, keccak256("committed.disposition"), "disposition is the consumer's, not the filer's");
    }

    function test_standing_acceptance_rejects_unlisted_filer_wrong_policy_subject_question() public {
        address[] memory filers = new address[](1); filers[0] = filer;
        bytes32 acc = standing(filers, p);
        T.IssueInput memory i = standingInput(acc, p, 1);

        vm.prank(rando);
        vm.expectRevert("ACDF: filer not accepted");
        reg.file(i);

        i.policyId = pAck;
        vm.prank(filer);
        vm.expectRevert("ACDF: policy not accepted");
        reg.file(i);

        i = standingInput(acc, p, 1); i.subject.target = address(0xDEAD);
        vm.prank(filer);
        vm.expectRevert("ACDF: subject not accepted");
        reg.file(i);

        i = standingInput(acc, p, 1); i.question = keccak256("other question");
        vm.prank(filer);
        vm.expectRevert("ACDF: question not accepted");
        reg.file(i);

        i = standingInput(keccak256("ghost"), p, 1);
        vm.prank(filer);
        vm.expectRevert("ACDF: acceptance unavailable");
        reg.file(i);
    }

    function test_revoked_or_expired_acceptance_blocks_new_filings_only() public {
        address[] memory none = new address[](0);
        bytes32 acc = standing(none, p);
        vm.prank(filer);
        bytes32 id = reg.file(standingInput(acc, p, 1));
        vm.prank(consumer);
        reg.revokeStandingAcceptance(acc);
        vm.prank(filer);
        vm.expectRevert("ACDF: acceptance unavailable");
        reg.file(standingInput(acc, p, 2));
        // the in-flight issue is untouched and completes under its committed rules
        vote(id, 0, 0, true); vote(id, 0, 1, true);
        reg.settleRound(id);
        assertFinalDecided(id, true);

        vm.prank(rando);
        vm.expectRevert("ACDF: not acceptance owner");
        reg.revokeStandingAcceptance(acc);
    }

    function test_acceptance_valid_until() public {
        T.StandingAcceptanceInput memory a;
        a.policyId = p; a.effectYes = E_YES; a.effectNo = E_NO; a.disposition = DISP;
        a.validUntil = uint64(vm.getBlockTimestamp() + 1 hours);
        a.filers = new address[](0);
        vm.prank(consumer);
        bytes32 acc = reg.registerStandingAcceptance(a);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(filer);
        vm.expectRevert("ACDF: acceptance expired");
        reg.file(standingInput(acc, p, 1));
    }

    // ---------------------------------------------------------------- POST_ACK

    function postAckInput(bytes32 policyId, uint256 id) internal view returns (T.IssueInput memory i) {
        i.policyId = policyId;
        i.mode = T.AcceptanceMode.POST_ACK;
        i.consumer = consumer;
        i.subject = subject(id);
        i.question = Q;
        i.effectYes = keccak256("proposed.yes");
        i.effectNo = keccak256("proposed.no");
        i.disposition = keccak256("proposed.disposition");
    }

    function test_post_ack_disabled_by_policy_reverts() public {
        vm.prank(filer);
        vm.expectRevert("ACDF: POST_ACK disabled");
        reg.file(postAckInput(p, 1));
    }

    function test_post_ack_stays_filed_until_acknowledged_and_no_vote_is_possible_before() public {
        vm.prank(filer);
        bytes32 id = reg.file(postAckInput(pAck, 1));
        assertEq(uint8(reg.getIssue(id).state), uint8(T.ProcedureState.Filed));
        assertEq(reg.getIssue(id).roundCount, 0);
        vm.prank(members[0]);
        vm.expectRevert("ACDF: not deciding");
        reg.castBallot(id, 0, true);

        // consumer acknowledges and commits the FINAL parameters; the filer's proposal is replaced
        vm.prank(consumer);
        reg.acknowledge(id, keccak256("ack.yes"), keccak256("ack.no"), keccak256("ack.disposition"), 0);
        T.Issue memory it = reg.getIssue(id);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Deciding));
        assertEq(uint8(it.effectClass), uint8(T.EffectClass.Binding));
        assertEq(it.effectYes, keccak256("ack.yes"));
        assertEq(it.disposition, keccak256("ack.disposition"));
        assertEq(it.roundCount, 1);
    }

    function test_only_the_named_consumer_may_acknowledge_and_only_within_the_window() public {
        vm.prank(filer);
        bytes32 id = reg.file(postAckInput(pAck, 1));
        vm.prank(rando);
        vm.expectRevert("ACDF: not the named consumer");
        reg.acknowledge(id, E_YES, E_NO, DISP, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(consumer);
        vm.expectRevert("ACDF: ack window closed");
        reg.acknowledge(id, E_YES, E_NO, DISP, 0);
    }

    function test_advisory_admission_after_window_cannot_be_upgraded_to_binding_later() public {
        vm.prank(filer);
        bytes32 id = reg.file(postAckInput(pAck, 1));
        vm.prank(rando);
        vm.expectRevert("ACDF: ack window open");
        reg.admitAdvisory(id);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        reg.admitAdvisory(id);
        T.Issue memory it = reg.getIssue(id);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Deciding));
        assertEq(uint8(it.effectClass), uint8(T.EffectClass.Advisory));
        assertEq(it.consumer, address(0));
        assertEq(it.effectYes, bytes32(0));
        assertEq(it.obligationKey, bytes32(0), "advisory issues bind no obligation");

        // votes come in and look favourable to someone — acknowledging now must be impossible
        vote(id, 0, 0, true); vote(id, 0, 1, true);
        vm.prank(consumer);
        vm.expectRevert("ACDF: not awaiting acknowledgment");
        reg.acknowledge(id, E_YES, E_NO, DISP, 0);
        reg.settleRound(id);
        assertFinalDecided(id, true);
        // ...and an Advisory result can never be "enacted" through the registry log
        vm.prank(consumer);
        vm.expectRevert("ACDF: not the consumer");
        reg.recordEnactment(id, E_YES, T.EnactmentStatus.Enacted, bytes32(0));
    }

    function test_acknowledge_after_admission_is_impossible_even_for_binding_issues() public {
        vm.prank(filer);
        bytes32 id = reg.file(postAckInput(pAck, 1));
        vm.prank(consumer);
        reg.acknowledge(id, E_YES, E_NO, DISP, 0);
        vote(id, 0, 0, true);
        vm.prank(consumer);
        vm.expectRevert("ACDF: not awaiting acknowledgment");
        reg.acknowledge(id, keccak256("changed.yes"), E_NO, DISP, 0); // there is no path to change parameters after admission
    }

    function test_strict_post_ack_expires_instead_of_going_advisory() public {
        vm.prank(filer);
        bytes32 id = reg.file(postAckInput(pAckStrict, 1));
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert("ACDF: advisory not allowed");
        reg.admitAdvisory(id);
        reg.expireUnacknowledged(id);
        T.Issue memory it = reg.getIssue(id);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Withdrawn));
        // and the lenient policy refuses the strict path
        vm.prank(filer);
        bytes32 id2 = reg.file(postAckInput(pAck, 2));
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert("ACDF: must admit as advisory");
        reg.expireUnacknowledged(id2);
    }

    function test_post_ack_requires_a_named_consumer() public {
        T.IssueInput memory i = postAckInput(pAck, 1);
        i.consumer = address(0);
        vm.prank(filer);
        vm.expectRevert("ACDF: consumer required");
        reg.file(i);
    }

    // ---------------------------------------------------------------- withdrawal

    function test_withdraw_only_while_filed_and_only_by_filer() public {
        vm.prank(filer);
        bytes32 id = reg.file(postAckInput(pAck, 1));
        vm.prank(rando);
        vm.expectRevert("ACDF: not filer");
        reg.withdraw(id);
        vm.prank(filer);
        reg.withdraw(id);
        assertEq(uint8(reg.getIssue(id).state), uint8(T.ProcedureState.Withdrawn));
        // withdrawn issues cannot be acknowledged or admitted
        vm.prank(consumer);
        vm.expectRevert("ACDF: not awaiting acknowledgment");
        reg.acknowledge(id, E_YES, E_NO, DISP, 0);
    }

    function test_no_unilateral_withdrawal_after_admission() public {
        bytes32 id = fileAsConsumer(p, 1); // consumer is also the filer here
        vm.prank(consumer);
        vm.expectRevert("ACDF: not withdrawable");
        reg.withdraw(id);
        vote(id, 0, 0, true);
        vm.prank(consumer);
        vm.expectRevert("ACDF: not withdrawable");
        reg.withdraw(id);
    }

    // ---------------------------------------------------------------- evidence

    function test_evidence_events_until_final() public {
        bytes32 id = fileAsConsumer(p, 1);
        vm.expectEmit(true, true, false, true);
        emit Evidence(id, rando, "ipfs://evidence-1");
        vm.prank(rando);
        reg.submitEvidence(id, "ipfs://evidence-1");
        vote(id, 0, 0, true); vote(id, 0, 1, true);
        reg.settleRound(id);
        vm.expectRevert("ACDF: evidence closed");
        reg.submitEvidence(id, "ipfs://too-late");
    }

    event Evidence(bytes32 indexed issueId, address indexed party, string evidenceURI);
}
