# ACDF v0.2 — Test record

Generated: 2026-10-06 (UTC), reference implementation v0.2.2 (round-bound on-chain ballots and submitter reports; consumer-committed obligation scope; policy-explicit appeal mode; adoptedFromEarlierRound). Re-run with `forge test`; regenerate vectors with `node tools/vectors.js`.

## Toolchain

- Foundry forge 1.5.1-stable (commit b0a9dd9c), solc 0.8.24+commit.e11b9ed9, via-IR, optimizer runs = 1
- forge-std v1.17.0 (`lib/forge-std`; install once with `forge install foundry-rs/forge-std`)
- Node 22 + ethers 6.17.0 (`tools/vectors.js`, vector generation only)
- ERC-8414 fixture: `test/fixtures/task-token/` vendored unmodified from github.com/garyyang-finchip/task-token-standard at commit `306a8f4046560ea181b1a967c18fb378e8871528` (TaskToken.sol, TaskVault.sol, interfaces/)

## Runtime sizes (EIP-170 limit 24,576 B)

| Contract | Runtime | Initcode |
|---|---|---|
| ACDFPolicyRegistry | 9,765 | 9,792 |
| ACDFRegistry | 24,212 | 24,537 |
| ACDFTaskTenderAdapter | 5,870 | 6,587 |

## Result

```
Ran 16 tests for test/ACDFAdapter8414.t.sol:ACDFAdapter8414Test
Suite result: ok. 16 passed; 0 failed; 0 skipped; finished in 9.14ms (7.25ms CPU time)
Ran 25 tests for test/ACDFAdmission.t.sol:ACDFAdmissionTest
Suite result: ok. 25 passed; 0 failed; 0 skipped; finished in 6.61ms (5.02ms CPU time)
Ran 26 tests for test/ACDFMinimal.t.sol:ACDFMinimalTest
Suite result: ok. 26 passed; 0 failed; 0 skipped; finished in 16.38ms (14.97ms CPU time)
Ran 5 tests for test/ACDFCaseB.t.sol:ACDFCaseBTest
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 6.88ms (5.18ms CPU time)
Ran 19 tests for test/ACDFRounds.t.sol:ACDFRoundsTest
Suite result: ok. 19 passed; 0 failed; 0 skipped; finished in 10.29ms (8.61ms CPU time)
Ran 10 tests for test/ACDFSigned.t.sol:ACDFSignedTest
Suite result: ok. 10 passed; 0 failed; 0 skipped; finished in 9.31ms (8.11ms CPU time)
Ran 23 tests for test/ACDFComposition.t.sol:ACDFCompositionTest
Suite result: ok. 23 passed; 0 failed; 0 skipped; finished in 18.19ms (17.01ms CPU time)
Ran 5 tests for test/ACDFVectors.t.sol:ACDFVectorsTest
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 343.71ms (441.01ms CPU time)
Ran 8 test suites in 381.53ms (420.51ms CPU time): 129 tests passed, 0 failed, 0 skipped (129 total tests)
```

The same result was reproduced from a fresh clone of github.com/garyyang-finchip/acd-framework after `forge install foundry-rs/forge-std`.

## Review test groups → suites

| Group | Suites |
|---|---|
| Minimal tally | ACDFMinimal.t.sol; ACDFVectors.t.sol (kofn-tally, 83 rows) |
| Acceptance and freezing | ACDFAdmission.t.sol (incl. obligation scopes) |
| Composition | ACDFComposition.t.sol; ACDFVectors.t.sol (composition, 192 rows) |
| Rounds and finality | ACDFRounds.t.sol (incl. appeal modes and adoption flag); ACDFCaseB.t.sol |
| Rules and verification | ACDFSigned.t.sol; ACDFVectors.t.sol (policy-id, ballot-digest, interface-ids); ACDFMinimal.t.sol (policy id, family versioning, ERC-165) |
| 8414 execution | ACDFAdapter8414.t.sol (real TaskToken fixture) |

## Test list

### ACDFAdapter8414.t.sol (16)

- test_NoDecision_triggers_nothing_and_the_task_clock_governs
- test_accept_path_pays_the_worker_through_the_real_kernel
- test_adapter_constructor_validates_inputs
- test_execute_unknown_issue_reverts
- test_execute_unknown_issue_reverts_and_adapter_is_a_judged_authority
- test_execution_failure_is_recorded_without_touching_the_decision_and_can_be_retried
- test_late_execution_fails_at_the_kernel_and_the_default_takes_over
- test_one_live_case_per_submission_and_no_relitigation_after_a_decision
- test_open_binds_the_exact_submission_and_both_8414_clocks
- test_open_rejects_non_pending_or_machine_path_submissions
- test_open_requires_room_under_settleBy_as_well
- test_open_requires_room_under_the_judgment_window
- test_open_requires_the_adapter_to_hold_the_judgment_right
- test_reject_path_releases_the_reservation
- test_reopen_allowed_after_NoDecision_while_time_remains
- test_task_updates_after_submission_do_not_change_the_version_being_judged

### ACDFAdmission.t.sol (25)

- test_acceptance_valid_until
- test_acknowledge_after_admission_is_impossible_even_for_binding_issues
- test_advisory_admission_after_window_cannot_be_upgraded_to_binding_later
- test_binding_issue_requires_an_obligation
- test_binding_requires_effects
- test_consumer_deadline_must_cover_the_whole_procedure
- test_consumer_filed_admits_atomically_as_binding
- test_evidence_events_until_final
- test_no_unilateral_withdrawal_after_admission
- test_obligation_identity_is_separate_from_subject_identity
- test_only_the_named_consumer_may_acknowledge_and_only_within_the_window
- test_post_ack_disabled_by_policy_reverts
- test_post_ack_requires_a_named_consumer
- test_post_ack_stays_filed_until_acknowledged_and_no_vote_is_possible_before
- test_revoked_or_expired_acceptance_blocks_new_filings_only
- test_same_obligation_cannot_be_filed_twice_while_open
- test_same_obligation_may_be_refiled_once_the_previous_issue_is_terminal
- test_standing_acceptance_binds_consumer_and_freezes_its_committed_parameters
- test_standing_acceptance_fixed_obligation_scope_covers_every_issue_under_it
- test_standing_acceptance_rejects_unlisted_filer_wrong_policy_subject_question
- test_standing_acceptance_zero_obligation_keys_the_duty_on_the_exact_subject
- test_strict_post_ack_expires_instead_of_going_advisory
- test_unauthorized_binding_consumer_mismatch_reverts
- test_unknown_policy_reverts
- test_withdraw_only_while_filed_and_only_by_filer

### ACDFCaseB.t.sol (5)

- test_caseB_appeal_round_NoDecision_keeps_round_one_rejection
- test_caseB_main_path_veto_silent_both_chambers_adopt_appeal_then_final
- test_caseB_only_listed_members_may_file_and_charter_can_revoke_for_new_filings
- test_caseB_variant1_elders_veto_inside_the_window
- test_caseB_variant2_econ_quorum_not_met_is_NoDecision_not_rejection

### ACDFComposition.t.sol (23)

- test_ALL_any_no_decides_no_without_waiting
- test_ALL_both_yes_is_yes_and_decided_at_the_later_chamber
- test_ALL_yes_plus_NoDecision_is_NoDecision_not_rejection_and_keeps_the_reason
- test_ANY_all_no_is_no_and_no_plus_NoDecision_is_NoDecision
- test_ANY_one_yes_passes_early_without_waiting_for_the_other_chamber
- test_KOFM_2of3_chambers
- test_VETO_exercised_inside_the_window_decides_no_with_reason_VETOED
- test_VETO_explicit_clearance_lets_the_target_pass_early
- test_VETO_late_veto_after_window_is_rejected_and_target_passes
- test_VETO_pass_through_cannot_settle_before_the_veto_window_closes
- test_VETO_require_clearance_explicit_clearance_and_veto
- test_VETO_require_clearance_silence_is_NoDecision_NO_CLEARANCE
- test_VETO_result_type_does_not_depend_on_settlement_order
- test_backward_or_self_edge_rejected_as_cycle
- test_body_kind_acceptance_mismatch_rejected
- test_duplicate_child_rejected
- test_empty_graph_bad_body_index_and_bad_k_rejected
- test_max_total_duration_must_cover_rounds_and_appeals
- test_submitter_body_report_is_accepted_only_from_the_pinned_submitter
- test_submitter_may_report_NoDecision_explicitly
- test_submitter_silence_is_NoDecision_SUBMITTER_SILENT_and_late_report_rejected
- test_unreferenced_node_and_doubly_referenced_node_rejected
- test_veto_target_must_be_a_later_node_and_veto_body_must_exist

### ACDFMinimal.t.sol (26)

- test_1of1_approve_is_final_decided_yes
- test_1of1_block_is_final_decided_no
- test_3of5_complementary_thresholds
- test_K1_of_5_needs_all_five_blocks_to_reject
- test_K1_of_5_single_approval_decides
- test_KN_of_5_single_block_rejects
- test_clock_mode
- test_deadline_without_threshold_is_NoDecision_not_rejection
- test_decision_instant_is_the_deciding_ballot_time
- test_duplicate_member_rejected
- test_duplicate_vote_reverts
- test_empty_roster_and_zero_window_rejected
- test_erc165_interface_ids
- test_family_versioning
- test_first_version_must_not_cite_previous
- test_illegal_thresholds_rejected
- test_late_vote_reverts
- test_no_ballots_at_all_is_NoDecision
- test_non_member_cannot_vote
- test_policy_id_is_the_hash_of_every_execution_parameter
- test_registered_policy_reads_back_the_executed_parameters
- test_signed_submission_rejected_for_on_chain_body_and_vice_versa
- test_vote_after_body_decided_reverts
- test_vote_at_exact_window_close_is_accepted
- test_vote_before_admission_or_after_final_reverts
- test_zero_member_rejected

### ACDFRounds.t.sol (19)

- test_NoDecision_appealable_opens_the_committed_window_first
- test_NoDecision_not_appealable_goes_straight_to_final
- test_appeal_mode_is_part_of_the_hashed_policy
- test_appeal_opens_round_two_whose_decision_supersedes_round_one
- test_appeal_round_NoDecision_keeps_the_previous_substantive_decision
- test_appeal_standing_consumer_or_filer
- test_appeal_window_runs_from_the_decision_instant_not_the_settlement_call
- test_appeals_exhausted_nothing_can_reopen_a_final_issue
- test_decided_round_becomes_provisional_then_final_after_the_window
- test_fresh_mode_appeal_that_decides_is_adopted_from_the_appeal_round
- test_fresh_mode_appeal_without_a_decision_ends_in_NoDecision
- test_hard_deadline_closes_an_issue_left_open_in_any_non_final_state
- test_no_substantive_decision_in_any_round_is_final_NoDecision
- test_old_round_signed_ballot_cannot_be_replayed_in_a_new_round
- test_on_chain_ballot_bound_to_a_settled_round_is_refused_in_the_next_round
- test_preserve_mode_marks_adoption_from_an_earlier_round
- test_round_deadline_and_hard_deadline_are_recorded_at_admission
- test_round_reads_are_bounds_checked
- test_submitter_report_bound_to_a_settled_round_is_refused_in_the_next_round

### ACDFSigned.t.sol (10)

- test_a_later_favourable_batch_cannot_rewrite_a_decided_body
- test_ballot_digest_is_eip712_bound_to_chain_and_registry
- test_erc1271_contract_voter_is_accepted
- test_forged_or_mismatched_signatures_revert
- test_high_s_and_bad_v_signatures_are_rejected
- test_late_signed_ballot_is_refused_by_arrival_time
- test_non_member_signature_and_batch_shape_are_refused
- test_same_voter_twice_and_contradictory_second_signature_are_refused
- test_tally_accumulates_across_batches_and_direct_ballots_are_refused
- test_valid_batch_tallies_exactly_like_on_chain_ballots

### ACDFVectors.t.sol (5)

- test_ballot_digest_vectors_match_ethers_typed_data
- test_composition_vectors
- test_interface_id_vectors
- test_kofn_tally_vectors
- test_policy_id_vectors_match_ethers_encoding

## Limitations stated

- Case B (`ACDFCaseB.t.sol`) uses a fixed roster snapshot and deterministic fixtures: it verifies composition, appeal and binding mechanics, not credit-qualified eligibility (ERC-8419 / ERC-8434), sybil resistance or random selection.
- The Foundry suites run against the vendored kernel in a local EVM. On Sepolia, against the live ERC-8414 TaskToken, the current contracts ran the accept path (Case A: Final x Decided(Yes), paid through `acceptFulfillment`) and the appeal path ending in NoDecision under REQUIRE_FRESH_DECISION (Case A2: round-1 Yes vacated, `execute` refused, kernel default governs): see `deployments/sepolia-cases.json` for addresses, transactions, events, decoded results and the bytecode comparison. The reject path, on-chain ballots, authorized submitters, composition and the PRESERVE adoption of an earlier round are covered by the local suites only.
- Tests read the clock through `vm.getBlockTimestamp()` instead of `block.timestamp` because via-IR may cache TIMESTAMP across `vm.warp`; the contracts under test are unaffected (single-transaction semantics).
