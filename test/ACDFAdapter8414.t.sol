// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";
import {ACDFTaskTenderAdapter} from "../assets/erc-acdf/contracts/adapters/ACDFTaskTenderAdapter.sol";
import {ITaskTenderKernel} from "../assets/erc-acdf/contracts/interfaces/ITaskTenderKernel.sol";
import {TaskToken} from "./fixtures/task-token/TaskToken.sol";
import {ITaskTender} from "./fixtures/task-token/interfaces/ITaskTender.sol";

/// Defensive-path fixture: a task whose views can be shaped freely (machine-settled or
/// non-pending submissions), since the real kernel never produces those under an adapter authority.
contract ShapedTask8414 {
    ITaskTenderKernel.Submission public sub;
    ITaskTenderKernel.TenderTerms public terms;
    address public authority;
    function set(address a, ITaskTenderKernel.Submission memory s, ITaskTenderKernel.TenderTerms memory t) external { authority = a; sub = s; terms = t; }
    function acceptanceAuthorityOf(uint256) external view returns (address) { return authority; }
    function submissionOf(uint256, uint256) external view returns (ITaskTenderKernel.Submission memory) { return sub; }
    function tenderTermsOf(uint256) external view returns (ITaskTenderKernel.TenderTerms memory) { return terms; }
    function taskOf(uint256) external pure returns (ITaskTenderKernel.TaskBinding memory b) { return b; }
    function acceptFulfillment(uint256, uint256) external {}
    function rejectFulfillment(uint256, uint256) external {}
}

/// Test group 6 — ERC-8414 adapter against the real TASK-KERNEL v3.0 TaskToken (vendored fixture).
contract ACDFAdapter8414Test is ACDFBase {
    TaskToken task;
    ACDFTaskTenderAdapter adapter;
    bytes32 p; // 3-of-5, 1 day, maxTotalDuration 2 days

    address owner     = address(0xA11CE);
    address publisher = address(0xB0B);
    address funder    = address(0xF00D);
    address worker    = address(0xCAFE);

    bytes32 TD  = sha256("TASK.md v1");
    bytes32 TH  = sha256("taskroot v1");
    bytes32 TH2 = sha256("taskroot v2");
    bytes32 RES = sha256("deliverable");

    uint64 constant MARGIN = 1 hours;

    function setUp() public override {
        super.setUp();
        task = new TaskToken("Task Token", "TASK");
        T.PolicySpec memory s = minimalSpec(5, 3, 1 days);
        s.family = keccak256("task-tender.acceptance");
        s.maxTotalDuration = 2 days;
        p = register(s);
        adapter = new ACDFTaskTenderAdapter(reg, ITaskTenderKernel(address(task)), p, MARGIN);
        vm.deal(funder, 100 ether);
    }

    function terms(uint64 judgmentWindow, uint64 settleBy, uint64 epochLength, uint64 perEpoch, uint64 maxCompletions)
        internal pure returns (ITaskTender.TenderTerms memory)
    {
        return ITaskTender.TenderTerms(address(0), 1 ether, maxCompletions, 0, settleBy, epochLength, perEpoch, judgmentWindow);
    }

    function mintWithAdapter(ITaskTender.TenderTerms memory t) internal returns (uint256 id) {
        id = task.mintTask(owner, publisher, address(adapter), TD, TH, "ipfs://task-v1", t);
        vm.prank(funder);
        task.fundTask{value: 2 ether}(id, 2 ether);
    }

    function submit(uint256 id, bytes32 res) internal returns (uint256 sid) {
        vm.prank(worker);
        sid = task.submitFulfillment(id, res, "ipfs://result");
    }

    function approve3(bytes32 issueId) internal { vote(issueId, 0, 0, true); vote(issueId, 0, 1, true); vote(issueId, 0, 2, true); }
    function reject3(bytes32 issueId)  internal { vote(issueId, 0, 0, false); vote(issueId, 0, 1, false); vote(issueId, 0, 2, false); }

    // ---------------------------------------------------------------- opening

    function test_open_binds_the_exact_submission_and_both_8414_clocks() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        uint64 submittedAt = uint64(vm.getBlockTimestamp());
        vm.prank(rando);
        bytes32 issueId = adapter.open(id, sid);

        T.Issue memory it = reg.getIssue(issueId);
        assertEq(uint8(it.state), uint8(T.ProcedureState.Deciding));
        assertEq(it.consumer, address(adapter));
        assertEq(it.filer, address(adapter), "the adapter files as consumer; the caller only triggers");
        assertEq(it.subject.target, address(task));
        assertEq(it.subject.id, id);
        assertEq(it.subject.dataHash, keccak256(abi.encode(sid, RES, uint64(1))), "resultHash and cited task version are bound");
        assertEq(it.question, adapter.QUESTION());
        assertEq(it.effectYes, adapter.EFFECT_ACCEPT());
        assertEq(it.effectNo, adapter.EFFECT_REJECT());
        assertEq(it.disposition, adapter.DISPOSITION());
        assertEq(it.consumerDeadline, submittedAt + 7 days - MARGIN, "judgment deadline minus execution margin");
        assertTrue(it.hardDeadline <= it.consumerDeadline);
        (bool exists,, uint256 tok, uint256 s,,,) = adapter.caseOf(issueId);
        assertTrue(exists); assertEq(tok, id); assertEq(s, sid);
    }

    function test_open_requires_room_under_the_judgment_window() public {
        // judgment window 1 day; policy needs 2 days + margin
        uint256 id = mintWithAdapter(terms(1 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        vm.expectRevert("ACDF: insufficient window");
        adapter.open(id, sid);
        // judgment window shorter than the margin itself
        uint256 id2 = mintWithAdapter(terms(30 minutes, 0, 0, 0, 2));
        uint256 sid2 = submit(id2, RES);
        vm.expectRevert("ACDFTender: no execution window");
        adapter.open(id2, sid2);
    }

    function test_open_requires_room_under_settleBy_as_well() public {
        // generous judgment window, but settleBy lands in 1 day: acceptFulfillment would be impossible
        uint64 settleBy = uint64(vm.getBlockTimestamp() + 1 days);
        uint256 id = mintWithAdapter(terms(7 days, settleBy, 0, 0, 2));
        uint256 sid = submit(id, RES);
        vm.expectRevert("ACDF: insufficient window");
        adapter.open(id, sid);
        // with settleBy far enough the earlier of the two clocks is the judgment window
        uint64 settleBy2 = uint64(vm.getBlockTimestamp() + 3 days);
        uint256 id2 = mintWithAdapter(terms(7 days, settleBy2, 0, 0, 2));
        uint256 sid2 = submit(id2, RES);
        bytes32 issueId = adapter.open(id2, sid2);
        assertEq(reg.getIssue(issueId).consumerDeadline, settleBy2 - MARGIN, "settleBy is the binding clock here");
    }

    function test_open_requires_the_adapter_to_hold_the_judgment_right() public {
        uint256 id = task.mintTask(owner, publisher, rando, TD, TH, "ipfs://task-v1", terms(7 days, 0, 0, 0, 2));
        vm.prank(funder);
        task.fundTask{value: 2 ether}(id, 2 ether);
        uint256 sid = submit(id, RES);
        vm.expectRevert("ACDFTender: not the acceptance authority");
        adapter.open(id, sid);
    }

    function test_open_rejects_non_pending_or_machine_path_submissions() public {
        ShapedTask8414 shaped = new ShapedTask8414();
        ACDFTaskTenderAdapter a2 = new ACDFTaskTenderAdapter(reg, ITaskTenderKernel(address(shaped)), p, MARGIN);
        ITaskTenderKernel.TenderTerms memory t;
        t.judgmentWindow = 7 days; t.rewardPerCompletion = 1 ether;
        ITaskTenderKernel.Submission memory s;
        s.fulfiller = worker; s.resultHash = RES; s.taskVersion = 1; s.submittedAt = uint64(vm.getBlockTimestamp());
        s.status = ITaskTenderKernel.SubmissionStatus.Accepted;
        shaped.set(address(a2), s, t);
        vm.expectRevert("ACDFTender: not pending");
        a2.open(1, 1);
        s.status = ITaskTenderKernel.SubmissionStatus.Pending; s.machineSettled = true;
        shaped.set(address(a2), s, t);
        vm.expectRevert("ACDFTender: machine-path submission");
        a2.open(1, 1);
    }

    function test_one_live_case_per_submission_and_no_relitigation_after_a_decision() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        bytes32 issueId = adapter.open(id, sid);
        vm.expectRevert("ACDFTender: case open or decided");
        adapter.open(id, sid);
        reject3(issueId);
        reg.settleRound(issueId);
        vm.expectRevert("ACDFTender: case open or decided"); // decided: re-filing cannot shop for another panel
        adapter.open(id, sid);
    }

    function test_reopen_allowed_after_NoDecision_while_time_remains() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        bytes32 first = adapter.open(id, sid);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(first);
        assertFinalNoDecision(first, T.Reason.QUORUM_NOT_MET);
        bytes32 second = adapter.open(id, sid); // 6 days minus margin remain: enough for another 2-day procedure
        assertTrue(second != first);
        assertEq(adapter.issueOf(adapter.caseKey(id, sid, RES, 1)), second);
    }

    // ---------------------------------------------------------------- execution

    function test_accept_path_pays_the_worker_through_the_real_kernel() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        bytes32 issueId = adapter.open(id, sid);
        approve3(issueId);
        vm.expectRevert("ACDFTender: not final");
        adapter.execute(issueId);
        reg.settleRound(issueId);
        assertFinalDecided(issueId, true);

        uint256 before = worker.balance;
        vm.expectEmit(true, true, true, true, address(task));
        emit FulfillmentAccepted(id, sid, worker, 1 ether);
        vm.prank(rando);
        adapter.execute(issueId);
        assertEq(worker.balance, before + 1 ether);
        assertEq(uint8(task.submissionOf(id, sid).status), uint8(ITaskTender.SubmissionStatus.Accepted));
        T.Enactment memory e = reg.getEnactment(issueId, address(adapter), adapter.EFFECT_ACCEPT());
        assertEq(uint8(e.status), uint8(T.EnactmentStatus.Enacted));
        assertEq(e.reporter, address(adapter));
        vm.expectRevert("ACDFTender: already enacted");
        adapter.execute(issueId);
    }

    function test_reject_path_releases_the_reservation() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        bytes32 issueId = adapter.open(id, sid);
        reject3(issueId);
        reg.settleRound(issueId);
        assertEq(task.pendingOf(id), 1);
        vm.expectEmit(true, true, false, true, address(task));
        emit FulfillmentRejected(id, sid);
        adapter.execute(issueId);
        assertEq(uint8(task.submissionOf(id, sid).status), uint8(ITaskTender.SubmissionStatus.Rejected));
        assertEq(task.pendingOf(id), 0);
        assertEq(uint8(reg.getEnactment(issueId, address(adapter), adapter.EFFECT_REJECT()).status), uint8(T.EnactmentStatus.Enacted));
    }

    function test_NoDecision_triggers_nothing_and_the_task_clock_governs() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        uint256 submittedAt = vm.getBlockTimestamp();
        bytes32 issueId = adapter.open(id, sid);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        reg.settleRound(issueId);
        assertFinalNoDecision(issueId, T.Reason.QUORUM_NOT_MET);
        vm.expectRevert("ACDFTender: no decision; judgment clock governs");
        adapter.execute(issueId);
        // the registry's early NoDecision does not start, stop or shorten 8414's own default
        vm.expectRevert("TaskToken: window open");
        task.claimUnjudged(id, sid);
        assertEq(uint8(task.submissionOf(id, sid).status), uint8(ITaskTender.SubmissionStatus.Pending));
        vm.warp(submittedAt + 7 days + 1);
        uint256 before = worker.balance;
        task.claimUnjudged(id, sid);
        assertEq(worker.balance, before + 1 ether, "silence pays the fulfiller, on 8414's clock");
    }

    function test_execution_failure_is_recorded_without_touching_the_decision_and_can_be_retried() public {
        // epoch pacing: one completion per day. Two decided acceptances in the same epoch:
        // the second accept reverts inside the kernel ("epoch exhausted"), is recorded as
        // Failed, and succeeds in the next epoch.
        uint256 id = mintWithAdapter(terms(7 days, 0, 1 days, 1, 2));
        uint256 sidA = submit(id, RES);
        uint256 sidB = submit(id, sha256("deliverable B"));
        bytes32 a = adapter.open(id, sidA);
        bytes32 b = adapter.open(id, sidB);
        approve3(a); approve3(b);
        reg.settleRound(a); reg.settleRound(b);
        adapter.execute(a);
        T.Result memory rb = result(b);
        adapter.execute(b); // fails inside acceptFulfillment: epoch exhausted
        T.Enactment memory e = reg.getEnactment(b, address(adapter), adapter.EFFECT_ACCEPT());
        assertEq(uint8(e.status), uint8(T.EnactmentStatus.Failed));
        (, bool enacted,,,,,) = adapter.caseOf(b);
        assertFalse(enacted);
        T.Result memory rb2 = result(b);
        assertEq(uint8(rb2.state), uint8(rb.state)); assertEq(rb2.outcomeYes, rb.outcomeYes);
        assertEq(uint8(task.submissionOf(id, sidB).status), uint8(ITaskTender.SubmissionStatus.Pending));

        vm.warp(vm.getBlockTimestamp() + 1 days);
        adapter.execute(b); // retry in the next epoch
        e = reg.getEnactment(b, address(adapter), adapter.EFFECT_ACCEPT());
        assertEq(uint8(e.status), uint8(T.EnactmentStatus.Enacted), "a later success overwrites Failed");
        assertEq(uint8(task.submissionOf(id, sidB).status), uint8(ITaskTender.SubmissionStatus.Accepted));
        // ...and a Failed report can never overwrite Enacted
        bytes32 acceptEffect = adapter.EFFECT_ACCEPT();
        vm.prank(address(adapter));
        vm.expectRevert("ACDF: already enacted");
        reg.recordEnactment(b, acceptEffect, T.EnactmentStatus.Failed, bytes32(0));
    }

    function test_late_execution_fails_at_the_kernel_and_the_default_takes_over() public {
        // 3-day judgment window, 2-day procedure: a rejection decided on day 1 but executed on
        // day 4 is refused by rejectFulfillment ("window closed"); the decision record stands,
        // the enactment is Failed, and claimUnjudged pays the worker. Arrival is what counts.
        uint256 id = mintWithAdapter(terms(3 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        uint256 submittedAt = vm.getBlockTimestamp();
        bytes32 issueId = adapter.open(id, sid);
        reject3(issueId);
        reg.settleRound(issueId);
        vm.warp(submittedAt + 3 days + 1);
        adapter.execute(issueId);
        assertEq(uint8(reg.getEnactment(issueId, address(adapter), adapter.EFFECT_REJECT()).status), uint8(T.EnactmentStatus.Failed));
        assertFinalDecided(issueId, false);
        task.claimUnjudged(id, sid);
        assertEq(uint8(task.submissionOf(id, sid).status), uint8(ITaskTender.SubmissionStatus.Accepted));
    }

    function test_task_updates_after_submission_do_not_change_the_version_being_judged() public {
        uint256 id = mintWithAdapter(terms(7 days, 0, 0, 0, 2));
        uint256 sid = submit(id, RES);
        vm.prank(publisher);
        task.updateTask(id, TD, TH2); // version 2 published after the work was delivered against v1
        assertEq(task.taskOf(id).version, 2);
        bytes32 issueId = adapter.open(id, sid);
        assertEq(reg.getIssue(issueId).subject.dataHash, keccak256(abi.encode(sid, RES, uint64(1))), "judged against the cited v1");
        approve3(issueId);
        reg.settleRound(issueId);
        adapter.execute(issueId);
        assertEq(uint8(task.submissionOf(id, sid).status), uint8(ITaskTender.SubmissionStatus.Accepted));
    }

    function test_execute_unknown_issue_reverts_and_adapter_is_a_judged_authority() public view {
        assertTrue(adapter.supportsInterface(0x01ffc9a7));
        assertFalse(adapter.supportsInterface(0xd2f3f3b4)); // not ITaskVerifier (any other id is false)
    }

    function test_execute_unknown_issue_reverts() public {
        vm.expectRevert("ACDFTender: unknown issue");
        adapter.execute(keccak256("nope"));
    }

    function test_adapter_constructor_validates_inputs() public {
        vm.expectRevert("ACDFTender: unknown policy");
        new ACDFTaskTenderAdapter(reg, ITaskTenderKernel(address(task)), keccak256("ghost"), MARGIN);
        vm.expectRevert("ACDFTender: zero address");
        new ACDFTaskTenderAdapter(reg, ITaskTenderKernel(address(0)), p, MARGIN);
    }

    event FulfillmentAccepted(uint256 indexed tokenId, uint256 indexed submissionId, address indexed fulfiller, uint256 reward);
    event FulfillmentRejected(uint256 indexed tokenId, uint256 indexed submissionId);
}
