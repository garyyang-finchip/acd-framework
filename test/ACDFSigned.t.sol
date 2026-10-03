// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ACDFBase} from "./ACDFBase.t.sol";
import {ACDFTypes as T} from "../assets/erc-acdf/contracts/ACDFTypes.sol";

/// Minimal ERC-1271 wallet: valid iff the digest was signed by `owner`.
contract MockWallet1271 {
    address public immutable owner;
    constructor(address owner_) { owner = owner_; }
    function isValidSignature(bytes32 digest, bytes memory sig) external view returns (bytes4) {
        if (sig.length != 65) return bytes4(0);
        bytes32 r; bytes32 s; uint8 v;
        assembly { r := mload(add(sig, 0x20)) s := mload(add(sig, 0x40)) v := byte(0, mload(add(sig, 0x60))) }
        return ecrecover(digest, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0);
    }
}

/// Test group 5 — signed-ballot acceptance and verification discipline.
contract ACDFSignedTest is ACDFBase {
    bytes32 p; // 3-of-5 SIGNED_BALLOTS body

    function setUp() public override {
        super.setUp();
        T.PolicySpec memory s = minimalSpec(5, 3, 1 days);
        s.family = keccak256("signed");
        s.bodies[0].acceptance = T.Acceptance.SIGNED_BALLOTS;
        p = register(s);
    }

    function batch(bytes32 id, uint256[] memory idx, bool[] memory approves) internal view
        returns (address[] memory v, bool[] memory a, bytes[] memory s)
    {
        v = new address[](idx.length); a = approves; s = new bytes[](idx.length);
        uint32 round = reg.getIssue(id).roundCount;
        for (uint256 i = 0; i < idx.length; i++) {
            v[i] = members[idx[i]];
            s[i] = sign(pk[idx[i]], reg.ballotDigest(id, round, 0, v[i], approves[i]));
        }
    }

    function idx(uint256 a) internal pure returns (uint256[] memory r) { r = new uint256[](1); r[0] = a; }
    function idx(uint256 a, uint256 b) internal pure returns (uint256[] memory r) { r = new uint256[](2); r[0] = a; r[1] = b; }
    function idx(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) { r = new uint256[](3); r[0] = a; r[1] = b; r[2] = c; }
    function yes(uint256 n) internal pure returns (bool[] memory r) { r = new bool[](n); for (uint256 i = 0; i < n; i++) r[i] = true; }
    function no(uint256 n) internal pure returns (bool[] memory r) { r = new bool[](n); }

    function test_valid_batch_tallies_exactly_like_on_chain_ballots() public {
        bytes32 id = fileAsConsumer(p, 1);
        (address[] memory v, bool[] memory a, bytes[] memory s) = batch(id, idx(0, 1, 2), yes(3));
        vm.prank(rando); // anyone may relay
        reg.submitSignedBallots(id, 0, v, a, s);
        assertTrue(reg.hasVoted(id, 1, 0, members[0]));
        T.BodyState memory bs = reg.getBodyState(id, 1, 0);
        assertEq(bs.yes, 3); assertEq(bs.no, 0);
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_tally_accumulates_across_batches_and_direct_ballots_are_refused() public {
        bytes32 id = fileAsConsumer(p, 1);
        (address[] memory v, bool[] memory a, bytes[] memory s) = batch(id, idx(0), yes(1));
        reg.submitSignedBallots(id, 0, v, a, s);
        (v, a, s) = batch(id, idx(1), no(1));
        reg.submitSignedBallots(id, 0, v, a, s);
        (v, a, s) = batch(id, idx(2), yes(1));
        reg.submitSignedBallots(id, 0, v, a, s);
        (T.NodeStatus st,,) = reg.bodyStatus(id, 1, 0);
        assertEq(uint8(st), uint8(T.NodeStatus.Pending), "2 yes 1 no of 3-of-5 is pending");
        vm.prank(members[3]);
        vm.expectRevert("ACDF: body not on-chain tally");
        reg.castBallot(id, 0, true);
        (v, a, s) = batch(id, idx(3), yes(1));
        reg.submitSignedBallots(id, 0, v, a, s);
        reg.settleRound(id);
        assertFinalDecided(id, true);
    }

    function test_a_later_favourable_batch_cannot_rewrite_a_decided_body() public {
        bytes32 id = fileAsConsumer(p, 1);
        (address[] memory v, bool[] memory a, bytes[] memory s) = batch(id, idx(0, 1, 2), no(3)); // 3 = N-K+1 blocks
        reg.submitSignedBallots(id, 0, v, a, s);
        (v, a, s) = batch(id, idx(3, 4), yes(2));
        vm.expectRevert("ACDF: body decided"); // "100% yes in this batch" is not "the round's ratio"
        reg.submitSignedBallots(id, 0, v, a, s);
        reg.settleRound(id);
        assertFinalDecided(id, false);
    }

    function test_forged_or_mismatched_signatures_revert() public {
        bytes32 id = fileAsConsumer(p, 1);
        address[] memory v = new address[](1); v[0] = members[0];
        bool[] memory a = new bool[](1); a[0] = true;
        bytes[] memory s = new bytes[](1);

        s[0] = sign(pk[1], reg.ballotDigest(id, 1, 0, members[0], true)); // signed by the wrong key
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);

        s[0] = sign(pk[0], reg.ballotDigest(id, 1, 0, members[0], false)); // voter signed NO, relayer claims YES
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);

        s[0] = sign(pk[0], reg.ballotDigest(id, 1, 1, members[0], true)); // signed for another body index
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);

        bytes32 other = fileAsConsumer(p, 2);
        s[0] = sign(pk[0], reg.ballotDigest(other, 1, 0, members[0], true)); // signed for another issue
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);

        s[0] = hex"deadbeef";
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);
    }

    function test_high_s_and_bad_v_signatures_are_rejected() public {
        bytes32 id = fileAsConsumer(p, 1);
        bytes32 digest = reg.ballotDigest(id, 1, 0, members[0], true);
        (uint8 vv, bytes32 r, bytes32 sv) = vm.sign(pk[0], digest);
        // malleated twin: s' = n - s, v' = flipped. Mathematically valid, rejected by the checker.
        bytes32 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 s2 = bytes32(uint256(n) - uint256(sv));
        uint8 v2 = vv == 27 ? 28 : 27;
        address[] memory v = new address[](1); v[0] = members[0];
        bool[] memory a = new bool[](1); a[0] = true;
        bytes[] memory s = new bytes[](1);
        s[0] = abi.encodePacked(r, s2, v2);
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);
        s[0] = abi.encodePacked(r, sv, uint8(vv + 2)); // v in {29,30} style garbage
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id, 0, v, a, s);
    }

    function test_same_voter_twice_and_contradictory_second_signature_are_refused() public {
        bytes32 id = fileAsConsumer(p, 1);
        (address[] memory v, bool[] memory a, bytes[] memory s) = batch(id, idx(0, 0), yes(2));
        vm.expectRevert("ACDF: already voted"); // identity is the key; a second signature buys nothing
        reg.submitSignedBallots(id, 0, v, a, s);

        (v, a, s) = batch(id, idx(0), yes(1));
        reg.submitSignedBallots(id, 0, v, a, s);
        (v, a, s) = batch(id, idx(0), no(1)); // the same voter also signed the opposite: provable contradiction
        vm.expectRevert("ACDF: already voted");
        reg.submitSignedBallots(id, 0, v, a, s);
    }

    function test_non_member_signature_and_batch_shape_are_refused() public {
        bytes32 id = fileAsConsumer(p, 1);
        uint256 strangerKey = uint256(keccak256("stranger"));
        address stranger = vm.addr(strangerKey);
        address[] memory v = new address[](1); v[0] = stranger;
        bool[] memory a = new bool[](1); a[0] = true;
        bytes[] memory s = new bytes[](1);
        s[0] = sign(strangerKey, reg.ballotDigest(id, 1, 0, stranger, true));
        vm.expectRevert("ACDF: not a member");
        reg.submitSignedBallots(id, 0, v, a, s);

        bool[] memory a2 = new bool[](2);
        vm.expectRevert("ACDF: batch shape");
        reg.submitSignedBallots(id, 0, v, a2, s);
        address[] memory none = new address[](0);
        vm.expectRevert("ACDF: batch shape");
        reg.submitSignedBallots(id, 0, none, new bool[](0), new bytes[](0));
    }

    function test_late_signed_ballot_is_refused_by_arrival_time() public {
        bytes32 id = fileAsConsumer(p, 1);
        (address[] memory v, bool[] memory a, bytes[] memory s) = batch(id, idx(0), yes(1)); // signed inside the window
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.expectRevert("ACDF: body window closed"); // ...but it arrives late
        reg.submitSignedBallots(id, 0, v, a, s);
    }

    function test_erc1271_contract_voter_is_accepted() public {
        uint256 ownerKey = uint256(keccak256("wallet-owner"));
        MockWallet1271 wallet = new MockWallet1271(vm.addr(ownerKey));
        T.PolicySpec memory s = minimalSpec(2, 2, 1 days);
        s.family = keccak256("signed.1271");
        s.bodies[0].acceptance = T.Acceptance.SIGNED_BALLOTS;
        s.bodies[0].members[1] = address(wallet);
        bytes32 pw = register(s);
        bytes32 id = fileAsConsumer(pw, 1);

        address[] memory v = new address[](2); v[0] = members[0]; v[1] = address(wallet);
        bool[] memory a = new bool[](2); a[0] = true; a[1] = true;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sign(pk[0], reg.ballotDigest(id, 1, 0, members[0], true));
        sigs[1] = sign(ownerKey, reg.ballotDigest(id, 1, 0, address(wallet), true));
        reg.submitSignedBallots(id, 0, v, a, sigs);
        reg.settleRound(id);
        assertFinalDecided(id, true);

        // the wallet rejects a signature by someone else
        bytes32 id2 = fileAsConsumer(pw, 2);
        sigs[0] = sign(pk[0], reg.ballotDigest(id2, 1, 0, members[0], true));
        sigs[1] = sign(pk[3], reg.ballotDigest(id2, 1, 0, address(wallet), true));
        vm.expectRevert("ACDF: bad signature");
        reg.submitSignedBallots(id2, 0, v, a, sigs);
    }

    function test_ballot_digest_is_eip712_bound_to_chain_and_registry() public view {
        bytes32 id = keccak256("issue");
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ACDF"), keccak256("1"), block.chainid, address(reg)));
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Ballot(bytes32 issueId,uint32 round,uint32 body,address voter,bool approve)"),
            id, uint32(1), uint32(0), members[0], true));
        assertEq(reg.ballotDigest(id, 1, 0, members[0], true), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }
}
