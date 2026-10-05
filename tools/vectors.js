#!/usr/bin/env node
// Generates the cross-language test vectors under assets/erc-acdf/vectors/.
//
//   policy-id.json      policyId = keccak256(abi.encode(PolicySpec)) for three canonical specs,
//                       computed with ethers' ABI coder (independent of solc) and re-derived in
//                       Solidity by test/ACDFVectors.t.sol.
//   ballot-digest.json  EIP-712 ballot digests for a fixed chainId / verifyingContract.
//   kofn-tally.json     K-of-N status truth table (rule re-implemented here in JS).
//   composition.json    ALL / ANY / 2-of-3 four-valued composition truth table.
//
// Run: node tools/vectors.js
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const out = path.join(__dirname, "..", "assets", "erc-acdf", "vectors");
fs.mkdirSync(out, { recursive: true });

const coder = ethers.AbiCoder.defaultAbiCoder();
const POLICY_TUPLE =
  "tuple(bytes32 family,uint32 version,bytes32 previous,address updateAuthority," +
  "tuple(uint8 kind,uint8 acceptance,address[] members,uint32 k,uint64 window)[] bodies," +
  "tuple(uint8 op,uint32 body,uint32 k,uint32 target,uint32 vetoBody,uint8 silence,uint32[] children)[] nodes," +
  "uint32 maxAppeals,uint64 appealWindow,uint8 appealable,uint8 appealStanding,uint8 appealMode,uint64 maxTotalDuration," +
  "uint64 ackWindow,bool allowAdvisory,bytes32 descriptorHash)";

const addr = (i) => ethers.getAddress("0x" + i.toString(16).padStart(40, "0"));
const DAY = 86400n, HOUR = 3600n;

// enums (must match ACDFTypes.sol)
const BodyKind = { ROSTER_KOFN: 0, AUTHORIZED_SUBMITTER: 1 };
const Acceptance = { ON_CHAIN_TALLY: 0, SIGNED_BALLOTS: 1, AUTHORIZED_SUBMITTER: 2 };
const Combinator = { BODY: 0, ALL: 1, ANY: 2, KOFM: 3, VETO: 4 };
const VetoSilence = { PASS_THROUGH: 0, REQUIRE_CLEARANCE: 1 };
const AppealStanding = { ANYONE: 0, CONSUMER_OR_FILER: 1 };
const AppealMode = { PRESERVE_UNLESS_OVERTURNED: 0, REQUIRE_FRESH_DECISION: 1 };

function base(family, bodies, nodes, extra = {}) {
  return {
    family: ethers.id(family),
    version: 1,
    previous: ethers.ZeroHash,
    updateAuthority: addr(0xA07),
    bodies, nodes,
    maxAppeals: 0, appealWindow: 0n, appealable: 0, appealStanding: AppealStanding.ANYONE,
    appealMode: AppealMode.PRESERVE_UNLESS_OVERTURNED,
    maxTotalDuration: 30n * DAY, ackWindow: 0n, allowAdvisory: false,
    descriptorHash: ethers.id("descriptor"),
    ...extra,
  };
}
const roster = (ids, k, window, acceptance = Acceptance.ON_CHAIN_TALLY) =>
  ({ kind: BodyKind.ROSTER_KOFN, acceptance, members: ids.map(addr), k, window });
const bodyNode = (body) => ({ op: Combinator.BODY, body, k: 0, target: 0, vetoBody: 0, silence: 0, children: [] });
const comb = (op, k, children) => ({ op, body: 0, k, target: 0, vetoBody: 0, silence: 0, children });
const veto = (target, vetoBody, silence) => ({ op: Combinator.VETO, body: 0, k: 0, target, vetoBody, silence, children: [] });

const specs = {
  "minimal-3of5": base("vector.minimal", [roster([1, 2, 3, 4, 5], 3, 1n * DAY)], [bodyNode(0)]),
  "two-chamber-all": base("vector.two-chamber",
    [roster([1, 2, 3], 2, 1n * DAY), roster([3, 4, 5], 2, 1n * DAY)],
    [comb(Combinator.ALL, 0, [1, 2]), bodyNode(0), bodyNode(1)]),
  "veto-over-all-with-appeal": base("vector.veto",
    [roster([4, 5], 1, 12n * HOUR), roster([1, 2, 3], 2, 2n * DAY, Acceptance.SIGNED_BALLOTS), roster([3, 4, 5], 2, 3n * DAY)],
    [veto(1, 0, VetoSilence.PASS_THROUGH), comb(Combinator.ALL, 0, [2, 3]), bodyNode(1), bodyNode(2)],
    { maxAppeals: 1, appealWindow: 2n * DAY, appealable: 3, appealMode: AppealMode.REQUIRE_FRESH_DECISION, maxTotalDuration: 10n * DAY }),
};

const policyVectors = Object.entries(specs).map(([name, spec]) => {
  const encoded = coder.encode([POLICY_TUPLE], [spec]);
  return {
    name,
    spec: JSON.parse(JSON.stringify(spec, (k, v) => (typeof v === "bigint" ? v.toString() : v))),
    abiEncoded: encoded,
    policyId: ethers.keccak256(encoded),
  };
});
fs.writeFileSync(path.join(out, "policy-id.json"), JSON.stringify({
  description: "policyId = keccak256(abi.encode(PolicySpec)); encoding by ethers v6 AbiCoder, verified against ACDFPolicyRegistry.policyIdOf in test/ACDFVectors.t.sol",
  tupleType: POLICY_TUPLE,
  count: policyVectors.length,
  vectors: policyVectors,
}, null, 2));

// ---------------------------------------------------------------- EIP-712 ballot digests
const chainId = 31337;
const verifyingContract = ethers.getAddress("0x00000000000000000000000000000000000acdf0");
const domain = { name: "ACDF", version: "1", chainId, verifyingContract };
const types = { Ballot: [
  { name: "issueId", type: "bytes32" }, { name: "round", type: "uint32" }, { name: "body", type: "uint32" },
  { name: "voter", type: "address" }, { name: "approve", type: "bool" } ] };
const ballots = [
  { issueId: ethers.id("issue-1"), round: 1, body: 0, voter: addr(1), approve: true },
  { issueId: ethers.id("issue-1"), round: 1, body: 0, voter: addr(1), approve: false },
  { issueId: ethers.id("issue-1"), round: 2, body: 0, voter: addr(1), approve: true },
  { issueId: ethers.id("issue-2"), round: 1, body: 3, voter: addr(0xBEEF), approve: true },
];
fs.writeFileSync(path.join(out, "ballot-digest.json"), JSON.stringify({
  description: "EIP-712 digests of Ballot(bytes32 issueId,uint32 round,uint32 body,address voter,bool approve) under domain {name:'ACDF',version:'1'}; verified against ACDFRegistry.ballotDigest etched at verifyingContract in test/ACDFVectors.t.sol",
  domain,
  count: ballots.length,
  vectors: ballots.map((b) => ({ ...b, digest: ethers.TypedDataEncoder.hash(domain, types, b) })),
}, null, 2));

// ---------------------------------------------------------------- K-of-N truth table (JS re-implementation)
function kofn(n, k, yes, no, closed) {
  if (yes >= k) return "Yes";
  if (no >= n - k + 1) return "No";
  return closed ? "NoDecision" : "Pending";
}
const tally = [];
for (const [n, k] of [[1, 1], [3, 1], [3, 2], [3, 3], [5, 1], [5, 3], [5, 5]]) {
  for (let no = 0; no <= n; no++) {
    for (let yes = 0; yes + no <= n; yes++) {
      // only sequences the registry can actually accept: ballots stop once the body is decided,
      // so a row must not contain votes cast after a decision (no-votes are cast first).
      const noDecides = no >= n - k + 1;
      if (noDecides && yes > 0) continue;
      if (no > n - k + 1) continue; // the (n-k+1)-th block decides; later blocks are refused
      if (yes > k) continue;        // the k-th approval decides; later approvals are refused
      for (const closed of [false, true]) {
        if (closed && (yes >= k || noDecides)) continue; // closing changes nothing once decided
        tally.push({ n, k, yes, no, closed, expected: kofn(n, k, yes, no, closed) });
      }
    }
  }
}
fs.writeFileSync(path.join(out, "kofn-tally.json"), JSON.stringify({
  description: "Minimal K-of-N body status. yes >= k → Yes; no >= n-k+1 → No; else NoDecision once the window closed, Pending before. Verified in test/ACDFVectors.t.sol.",
  count: tally.length,
  vectors: tally,
}, null, 2));

// ---------------------------------------------------------------- composition truth table
const VALS = ["Y", "N", "P", "D"];
function compose(op, children) {
  const m = children.length;
  const k = op === "ALL" ? m : op === "ANY" ? 1 : 2;
  const y = children.filter((c) => c === "Y").length;
  const n = children.filter((c) => c === "N").length;
  const p = children.filter((c) => c === "P").length;
  if (y >= k) return "Yes";
  if (n >= m - k + 1) return "No";
  if (p > 0) return "Pending";
  return "NoDecision";
}
const comp = [];
for (const op of ["ALL", "ANY", "KOFM2"]) {
  for (const a of VALS) for (const b of VALS) for (const c of VALS) {
    comp.push({ op, children: [a, b, c], expected: compose(op === "KOFM2" ? "KOFM" : op, [a, b, c]) });
  }
}
fs.writeFileSync(path.join(out, "composition.json"), JSON.stringify({
  description: "Four-valued composition over three children (Y=Decided yes, N=Decided no, P=Pending, D=NoDecision). KOFM2 = 2-of-3. Verified in test/ACDFVectors.t.sol with 1-of-1 bodies.",
  count: comp.length,
  vectors: comp,
}, null, 2));

// ---------------------------------------------------------------- ERC-165 interface ids
// XOR of all function selectors of each interface (events excluded). Recomputed from the compiled
// ABI when `out/` exists (forge build), otherwise the pinned values are written; test/ACDFVectors.t.sol
// asserts them against type(I).interfaceId, so a stale pin fails the suite.
function interfaceIdFromAbi(abi) {
  const tuple = (i) => (i.type.startsWith("tuple") ? "(" + i.components.map(tuple).join(",") + ")" + (i.type.endsWith("[]") ? "[]" : "") : i.type);
  let x = 0n;
  for (const f of abi) if (f.type === "function") x ^= BigInt(ethers.id(`${f.name}(${f.inputs.map(tuple).join(",")})`).slice(0, 10));
  return "0x" + x.toString(16).padStart(8, "0");
}
const pinned = { IACDFPolicyRegistry: "0x734a2e40", IACDFRegistry: "0x6cb878d2" };
const ids = {};
for (const name of Object.keys(pinned)) {
  const abiPath = path.join(__dirname, "..", "out", `${name}.sol`, `${name}.json`);
  ids[name] = fs.existsSync(abiPath) ? interfaceIdFromAbi(JSON.parse(fs.readFileSync(abiPath, "utf8")).abi) : pinned[name];
}
fs.writeFileSync(path.join(out, "interface-ids.json"), JSON.stringify({
  description: "ERC-165 interface identifiers (XOR of function selectors). Verified against type(I).interfaceId in test/ACDFVectors.t.sol.",
  ids,
}, null, 2));

console.log(`wrote ${policyVectors.length} policy-id, ${ballots.length} ballot-digest, ${tally.length} kofn-tally, ${comp.length} composition vectors to ${out}`);
