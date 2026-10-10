# Glint contracts

Work in progress. Glint supplies token facts, source rules and semantic projection APIs; consumers own graph and execution policy. Runtime closure is glint → published aegis → std. No LLVM, compiler Sema, lifetime verifier or checked-program execution is required.

## One immutable model

`Project.init` takes explicit source bytes, opaque labels, production/test classification, selected flags and import mappings. Glint opens no paths. `Options.lowering = false` omits std AstGen and explicitly records `not_requested` lowered coverage. The default remains lowered analysis. Snapshots own AST, optional std-generated ZIR, scopes, declarations, lexical references, comments and a separately identified partial lowered operation/reference index. Declaration `node` is the variable declaration, function prototype (not its enclosing `fn_decl`), container field or capture syntax node; a parameter uses its type expression, or its function prototype when no type expression exists. `token` is always the declaration name token. Declarations follow construction while visiting std AST nodes by index; function parameters and syntax captures are appended when their enclosing node is visited. References follow std AST node-index order. Neither array promises source-offset sorting. File, node and token identities use distinct published aegis ID domains. Handles check snapshot/generation; std AST/ZIR indexes remain the compiler's own types. Checked source-byte accounting bounds construction. Queries return const storage valid until project destruction; reports and projections have separate owners and cannot be rendered against a replacement snapshot.

`Project.syntax`, `lowered`, `declarations`, `scopes`, `references`, `operations` and import queries expose this same model. Source-mapped ZIR calls/member operations/reflection witnesses support conservative semantic facts. Missing imports, symbolic generics, cycles, unsupported structures and exhausted budgets remain explicitly unknown. There is no heuristic fallback that upgrades unknown to deadness or an exact graph.

## Compiled project rules

The public seam is `RuleContext`, `ProjectRule`, `RuleDefinition`, `runConfigured` and `FileConfig`. Built-ins use this same context and sink. A project rule supplies a callback and unique ID at least 1000, an ASCII name, group, purpose and nonzero version. Z/P/D prefixes belong to built-ins. IDs/names/collisions/configuration are validated before callbacks. Rules are statically compiled Zig, never loaded through a runtime ABI.

The context provides immutable checked model handles, conservative value/declaration resolution, primary/related diagnostic spans and explicit `undecided` coverage. The common runner copies temporary messages, orders diagnostics, applies real-comment suppression, and renders text, JSON version 1 and SARIF 2.1.0. Custom metadata appears in every format and coverage. Rule authors retain responsibility for their predicate; a callback cannot make unknown analysis complete by suppressing a finding.

`Config.selections` chooses `off`, `report` or `gate`. `FileConfig` overrides code options for an explicit FileId; callers select these IDs with their path dialect. Generic defaults remain Z003/Z013. `reviewed()` reports 21 IDs; `family()` reports the same selection except D001. Neither profile asserts family-green adoption. Unknown facts required by a selected gate make the run incomplete. Severity/group and acceptance level are distinct.

## Rules and policy options

| IDs | Contract |
|---|---|
| Z001, Z005, Z006, Z009, Z014, Z031, Z032 | Zig naming/style subset over known kinds; preserve established external ABI names. Unknown kinds are coverage. |
| Z003 | Std parser/lowering compatibility; rejected input is incomplete. |
| Z011 | Resolved deprecated call with declaration witness. |
| Z012 | Explicit family report: concrete private signature container without a public alias. Pointer/optional/error-union payload shapes and enclosing receiver identity are retained; unknown type shapes are coverage. |
| Z013 | Dead private import binding after lexical/member identity checks; unknown same-name members are not dead. |
| Z016 | Resolved std assertion conjunction advisory; no rewrite or evaluation-effect claim. |
| Z024 | Configurable byte-line readability report, default 100; never a universal gate. |
| Z026 | Explicit family report: every empty catch, including cleanup, needs a written site reason. Report before gate adoption. |
| P001 | Cast-site reasons. `casts = all` covers 22 std builtin conversion/integer/float/enum/error/pointer/backing-int tags, including boolean and volatile conversion; `pointer` preserves the predecessor's four `@constCast`, `@ptrCast`, `@alignCast`, `@intFromPtr` predicates. Real same-line `// safe: <reason>` required. `cast_scope = all` includes tests; explicit production scope preserves narrower migration policy. |
| P002 | Literal runtime-safety-off site needs a real same-line safe reason; computed toggles are undecided. A comment does not establish the invariant or measured hot-loop evidence. |
| P003 | Function length: default 120 inclusive declaration lines, subtract the largest contained returned type body for literal `type` constructors. Includes tests. Per-source named exceptions have a bounded line limit and nonempty reason; stale exceptions are coverage and required stale policy is incomplete. |
| P004 | Production `catch unreachable` needs same/previous-line real `// unreachable: <invariant>`. Existing test exemption is preserved explicitly. |
| P005 | Production use of the resolved mapped std.debug.print declaration; shadows/spelling lookalikes are not banned. Missing mapping is coverage. |
| P006 | Configurable disallowed declaration identity, qualified source-label/declaration with reason/replacement. Follows aliases, distinguishes siblings, rejects missing required targets through coverage; no default ban list. |
| D001 | Conservative private file/container declaration report on a completely resolved project use relation. Requires actual lowered lexical/member/call/reflection witnesses; public/exported or passed containers retain descendants for compiler hooks. Literal reflection resolves declarations; type-info retains containers. Dynamic reflection, generics, missing mappings, unsupported calls/hooks/lowering withhold every dead allegation. No reachability/SCC deletion inference. Default/family off; broad family admission remains undecided pending complete real-corpus resolution and triage. |

Z008 is absent. Removed Z002/Z004/Z007/Z010/Z015/Z017–Z023/Z025/Z027–Z030/Z033 remain rejected; no numeric alias or compatibility profile restores them. Breaking G2: typed public identities, rule metadata version 3, expanded explicit reviewed selection. JSON spans retain numeric file identities; JSON/SARIF and completion versions stay unchanged.

One actual inline or immediately preceding `// glint-ignore: ID -- site-written reason` suppresses one logical site. Malformed/unknown/ambiguous directives fail; strings cannot be reasons. Suppressed and stale counts are separate; strict stale policy is incomplete. Safety comments satisfy the configured source obligation, not proof of safety or a measured exception. The aegis pack validates its five documented exception classes and references; suppression cannot erase undecided coverage.

Operation and lexical-witness indexes scale with the bounded AST/ZIR inventory. Dead-private usage is computed once per project: one token/declaration witness index, retained-scope marks and one expansion over declarations and their scope ancestors. Resolution is shared and budgeted; unsupported work remains coverage. Projection owns a separate walk/output over the same frozen model, without reparsing. These are architecture cost bounds, not latency guarantees.

## Build helper and completion

A consumer imports this package's build module, obtains its pinned dependency, and calls `addLinter(b, dependency, .{ .source = b.path("project_rules.zig"), .target = b.graph.host })`. The entry calls `glint_cli.executeConfigured` with the static rule table; [the example](../examples/project.zig) is executable. `addLint(b, executable, .{ .sources = explicit_lazy_paths, .config = optional_json, .directories = caller_selected_directories, .inputs = other_exact_inputs })` declares native Zig file/config/directory-content dependencies. Directories invalidate the build; they never select glint files. Callers regenerate explicit source lists for additions/removals. There is no glob/path dialect here.

CLI JSON configuration is strict: `profile` (`core`, `none`, `reviewed`, `family`), `rules` with `id`/`level`, `max_line_length`, `max_function_lines`, `casts`, `cast_scope`, `function_exceptions`, `disallowed`, `fact_budget`, `strict_suppressions`. Unknown/duplicate fields or IDs fail. Libraries additionally support per-file options; a caller-owned linter applies file selections without inventing a glint path language.

Standalone exit classes remain 0 complete/clean, 1 complete/findings, 2 incomplete/input/tool/output/cancellation failure. Version-one completion records bind a fresh invocation ID, actual exit class, selected source count and exact flushed stdout length/hash. Output failure, input failure, interruption, truncation and incomplete-but-allowed findings cannot pass `Completion.verify`.

The build helper invokes the compiled linter through a build-only caller, with an unpredictable nonce and private scratch receipt. It verifies the unchanged receipt against child exit and captured JSON before accepting report-only diagnostics. Gate findings fail the build; every incomplete/signal/malformed/truncated/output failure fails independently of accepted findings. Receipt cleanup is best effort after consumption. It never treats a clean allowed-finding list as completed analysis.

## Two fact tiers

`dependency.module("glint_token")` exports the `Token.zig` API independently of aegis, AST, ZIR and semantic module mappings. `glint.Token` exports the same API from the full module. `scan(arena, bytes, observer)` copies a zero sentinel; `scanSentinel(arena, sentinel_bytes, observer)` borrows the caller's source. Fact arrays and decoded spellings live in the caller's arena, and unescaped spellings borrow source bytes. The caller keeps both alive until all facts are consumed.

Fast facts include literal imports, direct member spellings, simple private `const`/`var` import aliases, named test targets, ranges and conservative lazy declaration liveness. No import mapping is needed to recover a literal spelling. Computed import operands are explicit `unsupported` facts. A spelling is never promoted to a resolved declaration or type identity. Base imports appear in source order, with a direct member immediately after its base; alias-member uses follow in source order. Test ranges are disjoint, ordered inclusive byte offsets. The optional observer receives each token as the single pass over the source reaches it (punctuation one byte at a time, when asked for), for caller-owned token policies; no scan retains a public token array, and observing changes no fact. Invalid literals, allocation failure and input limits are returned errors, never clean coverage.

Semantic callers construct `Project` only when they need ownership, declaration or call facts. Named test targets and literal `@field`/`@hasDecl` references are indexed by the semantic projection. The default private-import check uses that same reflection resolver, distinguishes foreign declarations with the same spelling, and withholds dead allegations when required reflection names/receivers remain dynamic. Every untyped declaration literal remains indexed, including unmatched names. Matching names retain conservative lexical liveness, while semantic identity and the required type context remain explicitly unknown. Unresolved types inside pointer/optional/error-union receivers remain required Aegis coverage. Actual lexical aliases of `@import("builtin")` classify positive test arms and negated else arms; an unrelated value named `builtin` does not. Missing mappings remain required semantic coverage rather than blocking literal token facts. Source rejection (including a truncated UTF-8 character literal), absent required lowering and budget exhaustion cannot satisfy a semantic gate.

## Projection and adopter handoff

`Projection.init` owns imports, resolved references/calls, actual call ZIR witnesses and production/test/comptime/may-be-production contexts from the same snapshot. Escaped literals, named mappings, nested tests, reexports and lazy source retain their importing-use context. Unknown imports/calls make `complete` false; reference-level unknowns are separately explicit and consumers must reject any required unresolved reference. This is a conservative source projection, not an exact evaluated dependency graph. File identities follow input order; projection arrays follow that file order and standard AST node-index order. They do not promise source-offset sorting.

Gantry alone adapts these facts to its graph and owns architecture/layers/ownership/token-sequence/path policy. Its writer must run old/new fixture parity before deleting the independent Zig scanner. No adapter should copy scope or resolver algorithms. Preflight alone selects files/config through gantry's dialect, executes tools and verifies completion, owns layout/format/snippets/tests/CI, and removes its duplicate code predicates after equivalent adoption. G2 provides the glint APIs and exact handoff; neither consumer repo is modified here. Pin dependency order standalone glint → gantry → preflight, without reciprocal build/test pins or disabled closure checks. Embedded public-module tests import no shakedown; fault/allocation drivers belong to the package test root. Preflight adoption is externally owned: pin the published Glint main, use the full module for compiled rules and the completion/build-helper contract, and use `glint_token` for token facts. Glint pins green Preflight `e80b9a631956b1b7b7a7c6ebc69ec7e495ad623d` and Shakedown `e99eccb269dfeeb4569bce843743ec80c6e094c3` for its own CI/tests.

Published aegis `a5d17d0f346d8edacce34b86eea953eb096931da` supplies glint's typed IDs and checked byte counts, and the published operation contracts used by the optional G3 pack. Untrusted source bytes and bounded-budget leaves are not in this published API; their adoption remains a concrete later type dependency. SecretBytes is published at this pin; unfinished Choice/Order/Confined/own/bounded/scope branches are excluded. The pack uses AST/std ZIR heuristics; no verifier is pursued.


## Published aegis reports (G3)

The optional `AegisPack.rules` uses the public compiled-rule API. The standalone CLI registers
its IDs but never enables them by default; select `--enable A001` (through A005), or pass
report or gate selections and the pack descriptors to `runConfigured`. Explicit gate selection is accepted; an undecided required site still makes execution incomplete.
Generic defaults, Z026/Z012 reports and the deferred D001 admission are unchanged.

The rule context caches `sourceDigest(file)` once per immutable source per run, with caller-owned
scratch lifetime and handle validation. Operation contracts share that identity without global caches.
Recognition follows lexical declarations, explicit module mappings and exact source digests of
published aegis `a5d17d0f346d8edacce34b86eea953eb096931da`. It covers Secret, SecretBytes,
Guarded/Guard, ids, units and integer factories; it does not infer a secret or lock from a name.
Escaped member spellings use the same identifier decoder as ordinary facts; quoting an operation does not change its obligations. Copies of template/type aliases are excluded. Code changed from that operation contract is
unrecognized. A clean run does not establish security, ownership or complete coverage.

| ID/version | Obligation and supported report predicate | Prevention limit |
|---|---|---|
| A001/2 | Recognized secret backing or Guarded lock/data/capability field access must follow exposure and live-guard contracts. | Initialization, publication, intended safe internals and public-only secret components require review. No race/disclosure proof. |
| A002/2 | Direct lexical owner/capability copies require transfer; directly returned expose/value borrows require a lifetime mechanism. | Pointer aliases/type aliases excluded; lifetimes, live status, retained callers and field copies are undecided. |
| A003/2 | Local recognized acquisition at block end requires cleanup; direct cleanup twice or address use after cleanup is a local witness. | Only straight-line direct cleanup/defer/address discard. Other calls, error exits, transfers, branches, loops and aliases are undecided. No missing-errdefer allegation from proximity. |
| A004/2 | Immediate `raw()` arithmetic/comparison or narrowing/reconstruction cast must retain domain/unit/all-build failure semantics. | Raw boundaries can be intentional; no generic argument equality or raw value taint. Does not prove a mixed clock/domain or integer overflow. |
| A005/2 | SecretBytes.adopt requires full allocator extent/exclusive ownership; explicit end-bounded slice is a review site. | Slice syntax cannot prove allocation extent, provenance, alignment, successful transfer or wipe/free. Every recognized adoption records that uncertainty. |

Required unknown receivers and unsupported acquisition/cleanup or adoption sites record undecided coverage. General prevention limits describe the rule boundary; they are not unconditional per-file incompleteness.
Front-end rejection and budget exhaustion still make execution incomplete independently of
findings acceptance. The exact published implementation files are safe-type internals by declaration
identity; other source requires the same explicit site policy as consumers. Wiping inline padding
and full byte capacity, cleanup before free, borrow invalidation on successful reserve, one semantic
owner/guard and same-execution release remain runtime/caller obligations. Lint is not erasure proof.

Pack suppression is one real comment/site:
`// glint-ignore: A001 -- safe-type-internals: source-or-design-reference; site-specific reason`.
Accepted categories are `no-danger`, `design`, `measured-boundary`, `safe-type-internals`, and
`c-os-boundary`. Both a nonempty reference and written reason are required; the comment does
not prove either. Suppression cannot erase undecided coverage or certify incomplete execution.

These are explicitly adopted operation checks. Gate selection does not claim general security, flow or lifetime proof, and generic defaults remain unchanged.
Raw unadopted secrets/locks/domain integers are outside recognized declaration identity; a general
raw replacement rule needs evidence of actual danger, operation effects and complete triage first.
Unpublished constant-time Choice/Order/Confined/bounded/own/scope contracts are excluded.
Aegis scalar ABI guarantees cover non-exhaustive enums over 8–64-bit and native-size integers;
128-bit values remain Zig-only and are not included in that C ABI guarantee.
