#!/usr/bin/env python3
"""Build and lint the ethereum/ERCs submission package for the ACDF proposal.

Source of truth: ERCS/erc-acdf.md (ERC-8436; the number was assigned on 2026-10-05) and
assets/erc-acdf/{contracts,schemas,vectors}. The package mirrors the ERCs repository layout:

    <out>/ERCS/erc-<N>.md
    <out>/assets/erc-<N>/contracts/...   (links inside the ERC text are written ../assets/eip-<N>/...,
    <out>/assets/erc-<N>/schemas/...      because the ERCs site build renames erc-* to eip-*)
    <out>/assets/erc-<N>/vectors/...

Usage:
    python3 scripts/make-filing-package.py                       # ERC-8436 package from the source text
    python3 scripts/make-filing-package.py --number 8436 --discussions https://ethereum-magicians.org/t/erc-8436-agent-collective-decision-framework/29850

The script exits non-zero when any lint fails. Lints are a local approximation of the ERCs CI
(eipw + HTMLProofer) and of the repository rule "no Chinese in any shipped file"; they are not a
substitute for CI.
"""
import argparse, os, re, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_MD = os.path.join(ROOT, "ERCS", "erc-acdf.md")
SRC_ASSETS = os.path.join(ROOT, "assets", "erc-acdf")
PLACEHOLDER = "9999"   # historical working number; links still written with it are rewritten
NUMBER = "8436"        # assigned by the EIP editors on 2026-10-05

# Drafts that have not been merged into ethereum/ERCs: a literal "ERC-N" mention would require a
# link to a file that does not exist there (HTMLProofer 404) or be flagged by eipw's link-first rule.
UNMERGED = {"8338", "8414", "8419", "8434", "792", "1497"}
REQUIRED_SECTIONS = ["Abstract", "Motivation", "Specification", "Rationale", "Backwards Compatibility",
                     "Test Cases", "Reference Implementation", "Security Considerations", "Copyright"]
CJK = re.compile("[\\u3000-\\u303f\\u3400-\\u4dbf\\u4e00-\\u9fff\\uff00-\\uffef]")  # CJK punctuation, Han, fullwidth forms


def fail(msgs):
    for m in msgs:
        print("LINT FAIL:", m)
    sys.exit(1)


def lint_erc(text, number, discussions_ok):
    errors = []
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return ["preamble block missing"]
    pre = dict(line.split(": ", 1) for line in m.group(1).splitlines() if ": " in line)
    order = [line.split(":", 1)[0] for line in m.group(1).splitlines()]
    expected = ["eip", "title", "description", "author", "discussions-to", "status", "type", "category", "created", "requires"]
    if order != expected:
        errors.append(f"preamble field order {order} != {expected}")
    if pre.get("eip") != number:
        errors.append(f"eip field is {pre.get('eip')}, expected {number}")
    if len(pre.get("title", "")) > 44:
        errors.append(f"title longer than 44 characters ({len(pre['title'])})")
    desc = pre.get("description", "")
    if len(desc) > 140:
        errors.append(f"description longer than 140 characters ({len(desc)})")
    if re.search(r"\b(EIP|ERC)\b", desc) or ":" in desc:
        errors.append("description must not contain 'EIP', 'ERC' or a colon")
    if not re.match(r"^https://ethereum-magicians\.org/t/[^\s]+$", pre.get("discussions-to", "")) or "/t/TBD" in pre.get("discussions-to", ""):
        if not discussions_ok:
            errors.append("discussions-to must be a real Ethereum Magicians thread URL (pass --discussions)")
    reqs = pre.get("requires", "")
    nums = [int(x) for x in re.findall(r"\d+", reqs)]
    if nums != sorted(nums):
        errors.append("requires must be sorted ascending")
    body = text[m.end():]
    # sections and order
    heads = re.findall(r"^## (.+)$", body, re.M)
    idx = [heads.index(h) for h in REQUIRED_SECTIONS if h in heads]
    missing = [h for h in REQUIRED_SECTIONS if h not in heads]
    if missing:
        errors.append(f"missing sections: {missing}")
    if idx != sorted(idx):
        errors.append("required sections out of order")
    if not body.rstrip().endswith("Copyright and related rights waived via [CC0](../LICENSE.md)."):
        errors.append("file must end with the CC0 copyright line")
    # external URLs (only the preamble may carry the Magicians URL); the ERCs lint allows rfc-editor.org
    for url in re.findall(r"https?://[^\s)\]]+", body):
        if url.startswith("https://www.rfc-editor.org/rfc/"):
            continue
        errors.append(f"external URL in body: {url}")
    # unmerged drafts referenced by number
    for n in UNMERGED:
        if re.search(rf"\b(EIP|ERC)-{n}\b", body):
            errors.append(f"literal ERC-{n} mention: unmerged draft, refer to it descriptively")
    # first mention of every EIP/ERC must be a link to ./eip-N.md
    seen = set()
    for mm in re.finditer(r"(\[)?(EIP|ERC)-(\d+)(\]\(\./eip-(\d+)\.md\))?", body):
        n = mm.group(3)
        if n in seen:
            continue
        seen.add(n)
        if not (mm.group(1) and mm.group(4) and mm.group(5) == n):
            line = body[:mm.start()].count("\n") + 1 + m.group(0).count("\n")
            errors.append(f"first mention of {mm.group(2)}-{n} at line {line} is not a link to ./eip-{n}.md")
    # every eip-N link target that is one of the requires must be present, and placeholder links rewritten
    if f"eip-{PLACEHOLDER}/" in body and number != PLACEHOLDER:
        errors.append("placeholder asset links were not rewritten")
    if CJK.search(text):
        errors.append("CJK characters present in the ERC text")
    return errors, body


def check_asset_links(body, number, pkg_root):
    errors = []
    for link in re.findall(r"\]\((\.\./assets/eip-(\d+)/[^)]+)\)", body):
        rel, n = link
        if n != number:
            errors.append(f"asset link with wrong number: {rel}")
        local = os.path.join(pkg_root, "assets", f"erc-{n}", rel.split(f"/eip-{n}/", 1)[1])
        if not os.path.isfile(local):
            errors.append(f"asset link target missing in package: {rel}")
    return errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--number", default=NUMBER, help="ERC number to file under (default: 8436)")
    ap.add_argument("--discussions", default=None, help="Ethereum Magicians thread URL for discussions-to")
    ap.add_argument("--out", default=os.path.join(ROOT, "ercs-pr-package"))
    ap.add_argument("--allow-tbd", action="store_true", help="allow a TBD discussions-to (dry run only)")
    args = ap.parse_args()
    number = args.number

    text = open(SRC_MD, encoding="utf-8").read()
    text = re.sub(r"^eip: \d+$", f"eip: {number}", text, count=1, flags=re.M)
    if args.discussions:
        text = re.sub(r"^discussions-to: .*$", f"discussions-to: {args.discussions}", text, count=1, flags=re.M)
    text = text.replace(f"../assets/eip-{PLACEHOLDER}/", f"../assets/eip-{number}/")

    # build the package tree
    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(os.path.join(args.out, "ERCS"))
    dst_assets = os.path.join(args.out, "assets", f"erc-{number}")
    for sub in ("contracts", "schemas", "vectors"):
        shutil.copytree(os.path.join(SRC_ASSETS, sub), os.path.join(dst_assets, sub))
    md_path = os.path.join(args.out, "ERCS", f"erc-{number}.md")
    open(md_path, "w", encoding="utf-8").write(text)

    errors, body = lint_erc(text, number, args.allow_tbd)
    errors += check_asset_links(body, number, args.out)
    # no CJK anywhere in the package
    for root, _, files in os.walk(args.out):
        for f in files:
            p = os.path.join(root, f)
            try:
                if CJK.search(open(p, encoding="utf-8").read()):
                    errors.append(f"CJK characters in {os.path.relpath(p, args.out)}")
            except UnicodeDecodeError:
                errors.append(f"non-UTF-8 file in package: {os.path.relpath(p, args.out)}")
    if errors:
        fail(errors)
    n_files = sum(len(fs) for _, _, fs in os.walk(args.out))
    print(f"package ready: {args.out} ({n_files} files) -> ERCS/erc-{number}.md + assets/erc-{number}/")
    print("upload: ERCS/erc-%s.md to the branch's ERCS/ folder; drag assets/erc-%s/ into the branch's assets/ folder" % (number, number))


if __name__ == "__main__":
    main()
