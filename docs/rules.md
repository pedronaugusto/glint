# Reviewed rules, 2026-10-08

G1r reviews 32 ported identities against 1,228 tracked Zig files / 21,102,356 bytes at 19 published public main commits. Tests, examples and tracked benchmark baselines are included; package caches are excluded. Counts below are emitted G1 diagnostics (120-byte Z024), not confirmed defects. Zero counts are real enabled rows. Completion receipts are checked against invocation, actual exit and output hash. The initial relic run exhausted 100,000 facts; a preserved rerun with 1,000,000 completed. Current-style counts use the 100-byte report threshold.

The runtime remains std-only and path-free. The two inherited core checks remain defaults; `Config.reviewed()` / `--reviewed` selects all 12 retained rules for reporting. Correctness is the family gate group; Zig style reports before adoption/gating, and Z016 and Z024 stay advisory. The caller owns acceptance; G2/G4 must migrate the actual family configuration and reasons, so this review does not claim the family is green. Removed IDs, numeric slots, suppression directives and the old compatibility selector are rejected rather than mapped to aliases.

Zig style is limited to [the language guide](https://ziglang.org/documentation/0.17.0/#Style-Guide): naming, acronyms and its qualified line-length advice. Computed/reflected kinds are unknown. The style detector is a supported subset, not full type checking or enforcement of directory naming. Diagnostics keep JSON version 1, SARIF 2.1.0 and independent completion version 1; emitted rule version 2 records the reviewed groups.

| ID | Group | G1 hits | Decision / contract |
|---|---|---:|---|
| Z001 | Zig style | 2 | Non-type callable naming; preserve established external ABIs. |
| Z002 | removed | 0 | A named binding is not a discard. Prefix overlaps Z031; no ownership proof. |
| Z003 | correctness | 0 | Std parser incompatibility. Invalid semantic inputs make completion false. |
| Z004 | removed | 0 | Explicit versus anonymous initializer spelling is not a bug or Zig style obligation; overlaps Z010. |
| Z005 | Zig style | 0 | Type-producing callables use TitleCase. |
| Z006 | Zig style | 28 | Value bindings use snake_case; callable aliases use callable case. Unknown kind is coverage, never a name guess. |
| Z007 | removed | 0 | Aliases in different scopes may be intentional; redundant dependency spelling is not a bug. |
| Z009 | Zig style | 0 | Caller-supplied file-struct label with fields uses TitleCase. No path or directory rule. |
| Z010 | removed | 0 | Explicit initializer types are legal, often clarify coercion; no Zig style mandate. |
| Z011 | correctness | 56 | Resolved deprecated call and declaration witness: stale API migration. Warning, with reasoned site exceptions; not a runtime defect claim. |
| Z012 | removed | 11 | Private signature types are legal and may be inferred. Requiring public helper types broadens the public surface without a demonstrated bug. |
| Z013 | correctness | 4 | Unused private literal import binding, counted lexical identity; dead dependency after refactor. |
| Z014 | Zig style | 0 | Named error-set types use TitleCase. |
| Z015 | removed | 0 | Named private error sets in public functions are legal; no demonstrated bug, merged sets remain valid. |
| Z016 | family policy | 6 | Resolved standard assertion conjunction, report-only for failure localization. Preserve short circuit/evaluation effects; no automatic rewrite. |
| Z017 | removed | 17 | return try can matter for payload coercion and error traces; redundancy is not a bug. |
| Z018 | removed | 0 | Explicit coercion may document a boundary; no universal bug or style mandate. |
| Z019 | removed | 0 | @This spelling is legal; no rule imposed by the Zig style guide. |
| Z020 | removed | 43 | Same @This policy; no compulsory alias. |
| Z021 | removed | 0 | Same @This policy; caller labels are not semantic type identity. |
| Z022 | removed | 0 | Same @This policy; no compulsory Self name. |
| Z023 | removed | 236 | Receiver/comptime/Allocator/Io ranking is not an argument misuse proof or Zig style requirement. |
| Z024 | Zig style | 7424 | Aim for 100 bytes, use judgment. Configurable readability report; no universal line-length gate. |
| Z025 | removed | 0 | Captured error propagation is legal; spelling redundancy is not a bug. |
| Z026 | removed | 168 | Best-effort cleanup and cancellation may intentionally discard errors. No effect/intent contract supports a blanket gate. |
| Z027 | removed | 0 | Static access through an instance is legal; no demonstrated misuse. |
| Z028 | removed | 13 | Local/test imports are legal organization choices, not correctness. |
| Z029 | removed | 1 | Overlaps Z018, itself removed; no second coercion detector. |
| Z030 | removed | 13 | Poisoning is debug hygiene, not release safety or secret erasure. Blanket writes may be inappropriate after destruction. |
| Z031 | Zig style | 0 | Semantic names instead of underscore privacy metadata. Standalone discard and external ABIs remain valid. |
| Z032 | Zig style | 5 | Acronyms are ordinary words in callable/type names; preserve external ABI spelling. |
| Z033 | removed | 154 | The guide advises avoiding generic words but explicitly permits semantic exceptions. A word blacklist cannot judge qualified meaning; no blanket rule retained. |

Z008 has no implementation and remains absent. G1 compatibility ports remain reconstructible from its commit; keeping history does not keep removed checks active. Z019–Z022 collapse to zero rules, within the owner’s limit of at most one. Tests of retained deprecation, named imports, scopes, generic facts, ownership, reasoned suppressions, rendering and completion remain. The retired poison benchmark is replaced by an actual private-import row; parse/lower/cold/warm/allocation and mapped deprecation rows remain.

## Candidate admission

| Candidate | Group | Counted probe / decision |
|---|---|---|
| Dead private declarations | correctness, withheld | 4,772 lexical zero-reference candidates. Member calls, compiler hooks and reflection make these an upper screen, not resolved dead declarations. Broad admission is refused; Z013 remains the concrete import case. |
| Configurable disallowed declarations | family policy, withheld | 3,338 Mutex/print spelling sites demonstrate why text bans are rejected. The contract is resolved declaration identity per entry, with reason/replacement. Implement through the subsequent public rule seam; no blanket raw-mutex or writer ban. |
| Untrusted recursion without a bound | correctness, withheld | 194 resolved direct self-call sites; no claimed mutual-call closure, Untrusted reachability or bound contract. Read examples include depth-bounded generators. Await the admitted aegis pack; report first, hardened profile may later gate. |
| Cast and safety-off reasons | family policy, migration retained | 12,027 actual conversion tokens, 11,151 lacking same-line nonempty real safe comments, 11 safety-toggle sites. Includes tests/baselines; these are obligations, not unsafe-access findings. G2 must preserve every owner-required cast/safety-off reason and existing narrower predicates, exceptions and scopes through the public rule API. |
| Function length | family policy, migration retained | 40 inclusive function bodies above 120 lines. This screen does not subtract returned type bodies or apply project exceptions. G2 must preserve configured limits and bounded, reasoned exceptions; the unrelated 70-line policy is not inherited. |
| Universal recursion ban | removed | 194 direct self-calls; legitimate bounded recursion exists. Only the scoped untrusted candidate remains. |
| Universal usize ban | removed | 8,416 identifier spellings, including sizes/indexes. General libraries need native sizes; use typed indices where their admitted contract applies. |
| Allocation only at startup | removed | 1,758 alloc/create/resize spellings, not effects or phase facts. Runtime allocators are part of general library APIs. |
| Assertion density gate | removed | 1,058 assert spellings, not resolved invariants. Counts may be reported; they never prove invariants. Z016 is the retained advisory. |
| Unit suffix mandate | removed | 407 identifiers ending _ms. Spelling is not unit correctness; admitted unit types carry the obligation. |
| Opposing naming conventions | removed | Blanket snake_case functions/type files and preserved uppercase acronyms conflict with Zig style. The Z001/Z009/Z032 corpus rows above are the relevant counts. |

New correctness candidates are not admitted by partial inspection or synthetic fixtures. Raw probes, complete scan records, source-linked representative decisions and paired ReleaseFast results live only in private trials. No verifier or safety proof is planned. Gantry retains cross-file architecture and the path dialect; preflight retains orchestration. G2’s public-rule API, project helper, one predicate owner, projection parity and consumer migration are later work, as is glint’s own adoption of published aegis types. No unreleased branch dependency is introduced.
