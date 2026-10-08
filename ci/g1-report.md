# Glint G0/G1 evidence and remaining seams

This is an unreleased G0/G1 implementation. It preserves 32 selected compatibility IDs, not 32 adopted defaults. G2 orchestration/gantry integration, G3 safety-rule adoption and G4 predecessor retirement are outside this batch. No lifetime verifier or parked proof phase is designed. The owner's current std-only runtime scope takes precedence over later aegis adoption text in the book.

## Model and correctness

std AST, AstGen and ZIR feed immutable project/scopes/declarations/references. std-ZIR reference indexing is explicitly partial, separate from lexical resolution. Generic templates retain declaration identity without claiming instantiation; unknown import/type/comptime/flow information is coverage, never fabricated receiver/type evidence. The engine accepts bytes and opaque import edges and has no filesystem policy. The CLI supplies explicit filesystem inputs and boundaries; gantry will own family path dialect and architecture projection. Runtime imports are std only; shakedown and preflight are lazy own-tree test/build dependencies.

Corrected Z011 walks actual deprecated calls at every expression position and carries declaration witnesses. Z012 follows named aliases and enclosing-container visibility; Z015 preserves merged error-set and imported public provenance; Z023 recognizes the actual container receiver and resolved Allocator/Io ordering without spelling fallback. Z010 requires a known initializer context. Z018/Z029 share contextual coercion without duplicate findings. Z027 excludes resolved function aliases used as methods. Z030 consumes std ZIR as conservative debug-poison hygiene, with unsupported flow unknown; it proves no release safety, lifetime or erasure property.

Regression commits precede fixes. Retained failing logs cover declaration/prototype shadowing, generic/context coercion, public alias provenance, allocator-address reuse in handles/reports, related source witnesses, function aliases, and output/resource/help outcome classifications. `generic-corrected-regression.log` and `function-alias-regression.log` are the behavioral evidence; earlier fixture compilation failures are not behavioral regressions. [Rule contrasts](../src/Runner_test.zig), [public ownership/property/render contracts](../src/contract_test.zig), and [CLI failure contracts](../src/cli_test.zig) cover the new surface. The public consumer actually constructs/queries a project, runs selected checks and renders JSON.

## Completion contract

`--result FILE --run-id NONCE` is the machine-readable execution contract. Initial atomic replacement publishes running/incomplete. Only after selected analysis and required output write/flush succeed can final atomic replacement publish completed clean or findings, with exact output length/SHA-256 and invocation identity. Exit 0/1 is distinct from failure 2. Argument/input/traversal/cancellation/output/analysis-incomplete/tool failures have separate outcomes; help is not completion. Abrupt termination leaves running/incomplete or an unverified record. Sidecar publication failure itself cannot exit as completed. Atomic replacement is not a storage durability promise.

`Completion.verify` independently checks the version, required fields, nonce, outcome, selected count, exit class and captured bytes/hash. Finding acceptance belongs to a verified caller. Unknown facts can coexist with a completed bounded execution; invalid frontend or exhausted budgets cannot. JSON/SARIF analysis-complete fields alone do not attest completed output. Tests include genuine clean/findings, missing inputs/imports, cancellation, write and late-flush failure, stale/truncated/signal-like verification, and resource refusal. This does not unblock preflight's pinned predecessor or integrate Glint into preflight.

## Counted family scan

On 2026-10-08, frozen then-published main snapshots supplied **1,388 tracked Zig files / 24,301,107 bytes in 20 repositories**. No ship branch or shared working tree supplied source. The [public manifest](evidence/family-manifest.json) contains 19 public repositories, **1,179 selected files / 20,498,313 bytes**. Each file has bytes and SHA-256, and each repository has its full main SHA. Dependencies discovered for std facts are analysis inputs, not counted selected family files. Cloak's snapshot is its published three-file floor, not a worker's implementation.

All 19 public scans completed with findings and verified nonce/output receipts. The private Tycho snapshot has 209 selected files / 3,802,794 bytes and is explicitly incomplete: 18 files have parser-invalid Zig 0.17 source and 31 parser diagnostics. Its raw source witnesses stay private. Semantic rules skip invalid files; byte-line policy can still report them. No absence of findings on skipped files is safety evidence.

Every selected ID was compared against the corrected inherited pin `924b6b5dbc5848ceef77ebccc42470efdf7a1dc4`, with all 32 selected explicitly, including disabled-by-default Z033. The predecessor has no reliable execution-completion protocol; its output is a diagnostic compatibility oracle on known frozen inputs, never a clean-run certificate. Normalization uses `(ID, relative file, line)` because that oracle omits columns; duplicate occurrences on a line are preserved. The independently tested Zig differential driver reproduces every retained ledger row from raw artifacts.

The [32-ID inventory](evidence/rule-inventory.json) records zero-count IDs as well as findings. Public scans contain **395 differing sites / 417 changed occurrences** (405 added, 12 removed). The [per-site ledger](evidence/delta-adjudications.json) records source context, pinned source link, multiplicity, classification, inherited reason where present and explanation for every site. Full private raw artifacts, the independent comparison driver, all 20 repository counts and **971 site adjudications** are retained in [trials/glint](https://github.com/pedronaugusto/trials/tree/main/glint/results/2026-10-08-family).

| ID | Public added / removed | Explanation and admission status |
|---|---:|---|
| Z006 | 26 / 0 | Syntactic naming policy: 13 computed/reflected/C type-alias false-positive candidates, 9 already-reasoned RFC constants, 3 C constants, and one reflected value binding. No default admission. |
| Z011 | 7 / 0 | Actual deprecated APIs recovered in nested calls. No automatic rewrite. |
| Z012 | 11 / 0 | Private named C aliases and private enclosing API signatures. Visibility policy only. |
| Z013 | 4 / 0 | Dead private imports; field names/comments/re-export members do not reference the binding. Hygiene only. |
| Z016 | 6 / 0 | Mapped std assertion conjunctions; no OR/effect rewrite. |
| Z017 | 17 / 0 | Nested return-try positions; preserve return coercion. |
| Z020 | 2 / 0 | Inherited inline-This exceptions are not silently migrated. |
| Z023 | 168 / 12 | Actual-container ordering and recovered nested positions; 12 guessed receiver warnings become unknown coverage. |
| Z026 | 146 / 0 | Existing cleanup/best-effort suppressions use the predecessor spelling. Universal empty-catch default remains rejected. |
| Z029 | 1 / 0 | Known array-element coercion context. |
| Z030 | 9 / 0 | Debug-poison heuristic with intentional delegation/cleanup/erasure boundaries, no proof or new default. |
| Z032 | 5 / 0 | C/standardized naming exceptions; no admission. |
| Z033 | 3 / 0 | Recovered optional naming policy; still disabled by default. |

Other public IDs have no diagnostic delta. Private additions total 586 occurrences: 453 line-length occurrences in invalid-source files, 65 order warnings, 62 existing empty-catch suppression differences, 3 nested return-try sites, and one each deprecation, computed naming and debug-poison warning. The 111 instance-method alias false positives found during comparison were fixed before retaining the candidate results; they are not remaining warnings. These are detector/policy differences, not repaired family bugs.

## Own ReleaseFast measurements

Raw seven-round alternating paired outputs are [G0/G1](evidence/paired-core.json) and [before/after frozen import index](evidence/paired-import-index.json). The identical driver is fingerprinted and uses 256 declarations / 24,868 bytes, 15 repetitions, one source, 3,073 AST nodes and 4,097 ZIR instructions. The G0 reference is `c45f9fc0128b02170e1291f723c262a96de9f169`; pre-index candidate is `0a3414acd41c731297622742197ca8451f0d033d`. Bench fixtures must pass deterministic smoke before interpretation. This was a busy shared Darwin arm64 host (load is retained); best observed rows are evidence, not stable latency guarantees.

| Row | G0 best per repetition | G1 before index | G1 after index |
|---|---:|---:|---:|
| Parse | 80.4 µs | 79.9 µs | retained raw |
| std lowering | 500.7 µs | 501.5 µs | retained raw |
| Cold project/core | 791.6 µs | 983.0 µs | 907.9 µs |
| Warm core | 480.6 ns | 1,861.1 ns | 497.2 ns |

The repeated AST import walk caused the warm-core regression; indexing imports in the immutable model removed it (about 73% versus the measured pre-index pass). Cold construction remains about 16% above G0 in the final paired pass, with lexical resource guards, corrected parent/prototype indexes and explicit coverage. This cost is disclosed, not hidden behind a waived gate. Requested allocation count remains 8; peak requested bytes rise from 1,263,046 to 1,292,082 (2.3%), with zero live requested bytes after deinit. These are allocator-requested counts, not RSS.

An additional [exact-source final paired pass](evidence/paired-final-core.json) fingerprints candidate `6388ed2fd17b40f113464968fad63566baf8d2bb`, both binaries and the identical driver, and retains smoke plus all seven alternating pairs. Best G0/G1 rows are parse 79.7/79.3 µs, std lowering 496.5/493.5 µs, cold core 791.1/917.1 µs and warm core 475.0/497.3 ns. The cold cost is 15.9%; the warm difference is 4.7% at this sub-microsecond scale.

All-rule warm execution is about 248.1 µs in that final pass. G0 had no compatibility implementation, so its apparent all-rule row is unavailable and no speed ratio is claimed. [Current own rows](evidence/bench-final.log) additionally exercise a two-source mapped API fixture and std-ZIR debug-poison contrast. There is no edit-reuse/incremental-cache claim. Private process comparisons retain smoke receipts tied to driver, binaries and source fingerprint, seven alternating pairs, raw output and their non-equivalent-work limitations; no rival result is published here.

## Cast reasons and later seams

[evidence/cast-inventory.json](evidence/cast-inventory.json) inventories actual tokenizer builtin conversion sites across own build, source, tests, CI and benchmarks, including enum backing conversions, explicit type coercions, pointer/alignment casts and runtime-safety toggles. Strings/comments are excluded by the std tokenizer. All 182 actual conversions have a local `// safe:` reason, including representation bounds and allocator context type/alignment. No runtime-safety disabling is present. The inventory does not redefine the book's broader cast-reason policy as just a few pointer casts.

G1 preserves the inventory and written reasons; it does not add a G3 cast-enforcement default. Owner decisions for later G1r/G3 include treatment of reflected naming aliases, standardized constants, intentional catch/deinit boundaries, and admission quality. Those warnings remain explicit opt-in policy, not a new family gate. G2 seams are caller-owned classification/path dialect, opaque module mapping, std/Allocator/Io identities, architecture projection and configuration/version contracts. G4 owns migration of existing suppression spelling and retirement only after consumer comparison; the fork remains in place. No compatibility shim or package-owned planner was introduced.

The book's package status still describes an earlier floor; updating it belongs to nav/owner after landing, not this ship. No book file, other worker clone, preflight or predecessor source was changed. Public/private visibility was retained and no release/tag was created.

## Gates and pins

Published preflight main `9af905ed85cab6dbb19d9431c65ee3f41fbaa74d` had green main runs 37711386950 and 37710302704 before pinning. Published shakedown main `9357a9ab398ac25fa8a408a71e77a124bc51d311` had green exact-main run 37820085077 before refreshing the pin. The scan's earlier shakedown source snapshot is separately frozen in the manifest; it is not the package dependency pin.

The first floor established main without force and the default branch was verified. Working fast CI was green at `f43f7489a849f6161e139d1b7be5dcfad44f860a` ([run 37825478130](https://github.com/pedronaugusto/glint/actions/runs/37825478130)). Final fast and exact-head merge runs are required before advancing main. CI matrices are regenerated by `zig build plan` through the pinned preflight, never by a package planner. The merge tier compiles portable tests once and runs them on macOS and Windows alongside Linux checks. Final landing records belong to the verified Actions run attached to the eventual main SHA; this report does not anticipate a green gate.

An optional nav progress mark was rejected by automatic approval review because it combined private-corpus status with an unverified board destination. It was not retried or bypassed; repository evidence and gates remain independent of that optional notification.
