# PR #2046 reply to the editor review (jochem-brouwer)

Post as one comment on the pull request after the branch is updated; reply "Done" under each inline
comment and resolve it; then re-request review.

---

@jochem-brouwer Thank you for the thorough review, for recomputing the vectors, and for clearing the cache.

All five points are addressed in the latest commit on this branch:

1. RFC 2119 / RFC 8174 are now linked (rfc-editor.org).
2. Sections 4 and 11 declare `supportsInterface(bytes4)` in both interface listings, so the identifiers derived from the text match Section 15 (`0xb362eb4e` / `0xd31aae30`); no identifier and no registry contract changed.
3. Test Cases refers to nothing outside the proposal: the generator reference is gone (the vector files are deterministic and state how their values were produced), and the test-suite paragraph is now informative context the document explicitly does not depend on.
4. The vendored kernel interface is `ITaskTenderKernel.sol` / `ITaskTenderKernel`; the adapter's import, comments, revert prefix (`ACDFTender:`) and the label preimages behind its effect and disposition identifiers are number-neutral as well, so no proposal number appears in the assets. The adapter's bytecode changes accordingly; the registries are untouched.
5. Security Considerations no longer uses RFC 2119 keywords. Each sentence that carried one restated a requirement already present in the Specification (Sections 5.2 and 5.3), which the text now points to instead.

Re-requesting your review.
