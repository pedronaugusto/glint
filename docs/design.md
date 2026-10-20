# Glint contracts

Work in progress. Glint supplies token facts, a semantic model and source rules; consumers own graph and execution policy. Runtime closure is glint → published aegis → std. No LLVM, compiler Sema, lifetime verifier or checked-program execution is required.

## One immutable model

`Project.init` takes explicit source bytes, opaque labels, production/test classification, selected flags, import mappings and, per file, the module names its build binds in no module that compiles it (`absent`: code that needs one is not compiled in this build; an unmapped name the caller does not state absent stays unknown). Glint opens no paths. `Options.lowering = false` omits std AstGen and explicitly records `not_requested` lowered coverage. The default remains lowered analysis. Snapshots own AST, optional std-generated ZIR, scopes, declarations, lexical references, comments and a separately identified partial lowered operation/reference index. Declaration `node` is the variable declaration, function prototype (not its enclosing `fn_decl`), container field or capture syntax node; a parameter uses its type expression, or its function prototype when no type expression exists. `token` is always the declaration name token. Declarations follow construction while visiting std AST nodes by index; function parameters and syntax captures are appended when their enclosing node is visited. References follow std AST node-index order. Neither array promises source-offset sorting. File, node and token identities use distinct published aegis ID domains. Handles check snapshot/generation; std AST/ZIR indexes remain the compiler's own types. Checked source-byte accounting bounds construction. Queries return const storage valid until project destruction; reports have their own owner and cannot be rendered against a replacement snapshot.

`Project.syntax`, `lowered`, `declarations`, `scopes`, `references`, `operations` and import queries expose this same model. Source-mapped ZIR calls/member operations/reflection witnesses support conservative semantic facts. Missing imports, symbolic generics, cycles, unsupported structures and exhausted budgets remain explicitly unknown. There is no heuristic fallback that upgrades unknown to deadness or an exact graph.

## Compiled project rules

The public seam is `RuleContext`, `ProjectRule`, `RuleDefinition`, `runConfigured` and `FileConfig`. Built-ins use this same context and sink. A project rule supplies a callback and unique ID at least 1000, an ASCII name, group, purpose and nonzero version. Z/P/D prefixes belong to built-ins. IDs/names/collisions/configuration are validated before callbacks. Rules are statically compiled Zig, never loaded through a runtime ABI.

The context provides immutable checked model handles, conservative value/declaration resolution, primary/related diagnostic spans and explicit `undecided` coverage. The common runner copies temporary messages, orders diagnostics, applies real-comment suppression, and renders text, JSON version 1 and SARIF 2.1.0. Custom metadata appears in every format and coverage. Rule authors retain responsibility for their predicate; a callback cannot make unknown analysis complete by suppressing a finding.

`Config.selections` chooses `off`, `report` or `gate`. `FileConfig` overrides code options for an explicit FileId; callers select these IDs with their path dialect. Generic defaults remain Z003/Z013. `reviewed()` reports 21 IDs; `family()` reports the same selection. Neither profile asserts family-green adoption. Unknown facts required by a selected gate make the run incomplete. Severity/group and acceptance level are distinct.

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
| Z026 | Correctness: every empty catch, including cleanup, needs a written site reason, since a discarded error is a result nobody read. Not in the generic default selection; preflight's default policy gates it. |
| P001 | Cast-site reasons. `casts = all` covers 22 std builtin conversion/integer/float/enum/error/pointer/backing-int tags, including boolean and volatile conversion; `pointer` preserves the predecessor's four `@constCast`, `@ptrCast`, `@alignCast`, `@intFromPtr` predicates. Real same-line `// safe: <reason>` required. `cast_scope = all` includes tests; explicit production scope preserves narrower migration policy. |
| P002 | Literal runtime-safety-off site needs a real same-line safe reason; computed toggles are undecided. A comment does not establish the invariant or measured hot-loop evidence. |
| P003 | Function length: default 120 inclusive declaration lines, subtract the largest contained returned type body for literal `type` constructors. Includes tests. Per-source named exceptions have a bounded line limit and nonempty reason; stale exceptions are coverage and required stale policy is incomplete. |
| P004 | Production `catch unreachable` needs same/previous-line real `// unreachable: <invariant>`. Existing test exemption is preserved explicitly. |
| P005 | Production use of the resolved mapped std.debug.print declaration; shadows/spelling lookalikes are not banned. Missing mapping is coverage. |
| P006 | Declarations a project keeps out of its code, decided by what each reference resolves to: one named from a module as programs import it (`std`'s `posix.fdatasync`) or from a `.zig` input, each per-build choice on its path read in every alternative; or an external function by its symbol, which every `extern fn` of it binds (a governed `extern fn` governs its symbol too, so the program's own `extern fn fsync` is std's `c.fsync`). Identifiers, member accesses and `@field` with a written name that spell a governed name are resolved; an alias is found where it is made. A governed name whose receiver does not resolve is undecided unless Zig refuses every candidate at the site (called: by count or a literal where a struct is taken, as a method and as a namespace function; not called: the value of a declaration the file uses as a member receiver, which no function or number is), a module no file imports is nothing to check, a `.zig` source that is no input is coverage. `scope = production` leaves tests and test blocks out. An entry names the packages that own its declaration (`owners`, matched against each input's `package`, which the caller states; the CLI's `--package NAME=DIR`, the innermost directory winning): their files are where it is meant to be used and are not governed by it. A site outside them that must use it is a reasoned suppression. No default list: preflight's policy gives the family's (durability belongs to airlock). |
| D001 | A private declaration (no `pub`, not exported, a function or variable at file or container level, an import aside: Z013) that its file names nowhere. Zig lets only the declaring file use one: another file's member access or `@field` is refused, `@hasDecl` sees no private declaration even in its own file, type information lists only public names, so no std hook calls a private `format`. Every spelling of the name in the file is a use (an identifier, a member access or declaration literal `.name`, `@field` with that name) unless the identifier resolves lexically to another declaration; a struct literal's field name and a use inside the declaration itself are not. A `@field` with a computed name reaches nothing on a run-time value (it names only fields there), every declaration of its receiver's container on a type, and withholds the file's findings when its receiver could be a type and does not resolve. A declaration inside a reported container is not reported again. No reachability: a declaration only dead code names is used. In the family profile at report (admitted 2026-10-18 on the family's mains: every finding a declaration named nowhere else, no false alarm). |

Z008 is absent. Removed Z002/Z004/Z007/Z010/Z015/Z017–Z023/Z025/Z027–Z030/Z033 remain rejected; no numeric alias or compatibility profile restores them. Breaking G2: typed public identities, rule metadata version 3, expanded explicit reviewed selection. JSON spans retain numeric file identities; JSON/SARIF and completion versions stay unchanged.

One actual inline or immediately preceding `// glint-ignore: ID -- site-written reason` suppresses one logical site. Malformed/unknown/ambiguous directives fail; strings cannot be reasons. Suppressed and stale counts are separate; strict stale policy is incomplete. Safety comments satisfy the configured source obligation, not proof of safety or a measured exception. The aegis pack validates its five documented exception classes and references; suppression cannot erase undecided coverage.

Operation and lexical-witness indexes scale with the bounded AST/ZIR inventory. Dead-private usage is computed once per project: one token/declaration witness index, retained-scope marks and one expansion over declarations and their scope ancestors. Resolution is shared and budgeted; unsupported work remains coverage. These are architecture cost bounds, not latency guarantees.

## Assertion metrics

`Config.metrics` (CLI `--metrics`, config `metrics`) adds `Report.metrics`: per selected file and in total, the functions with a body (test blocks are not functions), how many make an assertion call in their own body, and the assertion calls by the declaration the callee resolves to: std's `debug.assert` and aegis's `assert.invariant`, `pre`, `post`, `never`, `debug` and `debugCheck`, found through the modules the program imports them by (`std`, `aegis`, `aegis.assert`) like any library role. A call spelled like one whose callee does not resolve is counted as unresolved, never as an assertion. Text prints one `metrics:` line; JSON adds a `metrics` object. A count is a report, never a gate or a proof: it says nothing about what an assertion checks.

## Build helper and completion

A consumer imports this package's build module, obtains its pinned dependency, and calls `addLinter(b, dependency, .{ .source = b.path("project_rules.zig"), .target = b.graph.host })`. The entry calls `glint.cli.executeConfigured` with the static rule table; [the example](../examples/project.zig) is executable. `addLint(b, executable, .{ .sources = explicit_lazy_paths, .config = optional_json, .directories = caller_selected_directories, .inputs = other_exact_inputs })` declares native Zig file/config/directory-content dependencies. Directories invalidate the build; they never select glint files. Callers regenerate explicit source lists for additions/removals. There is no glob/path dialect here.

CLI JSON configuration is strict: `profile` (`core`, `none`, `reviewed`, `family`), `rules` with `id`/`level`, `max_line_length`, `max_function_lines`, `casts`, `cast_scope`, `function_exceptions`, `disallowed`, `fact_budget`, `strict_suppressions`, `metrics`. Unknown/duplicate fields or IDs fail. Libraries additionally support per-file options; a caller-owned linter applies file selections without inventing a glint path language.

Standalone exit classes remain 0 complete/clean, 1 complete/findings, 2 incomplete/input/tool/output/cancellation failure. Version-one completion records bind a fresh invocation ID, actual exit class, selected source count and exact flushed stdout length/hash. Output failure, input failure, interruption, truncation and incomplete-but-allowed findings cannot pass `Completion.verify`.

The build helper invokes the compiled linter through a build-only caller, with an unpredictable nonce and private scratch receipt. It verifies the unchanged receipt against child exit and captured JSON before accepting report-only diagnostics. Gate findings fail the build; every incomplete/signal/malformed/truncated/output failure fails independently of accepted findings. Receipt cleanup is best effort after consumption. It never treats a clean allowed-finding list as completed analysis.

## Two fact tiers

`glint.token` is the `Token.zig` API. It is a namespace of the one `glint` module, not a module of its own: a program that uses only it analyzes and links only std, because Zig compiles what is referenced. The portable contract (`check-token-portable`) compiles `Token.zig` alone for a 32-bit freestanding target to keep that so. Fetching the package still fetches aegis, which the semantic part needs. `scan(arena, bytes, observer)` copies a zero sentinel; `scanSentinel(arena, sentinel_bytes, observer)` borrows the caller's source. Fact arrays and decoded spellings live in the caller's arena, and unescaped spellings borrow source bytes. The caller keeps both alive until all facts are consumed.

Fast facts include literal imports, direct member spellings, simple private `const`/`var` import aliases, named test targets, ranges and conservative lazy declaration liveness. No import mapping is needed to recover a literal spelling. Computed import operands are explicit `unsupported` facts. A spelling is never promoted to a resolved declaration or type identity. Base imports appear in source order, with a direct member immediately after its base; alias-member uses follow in source order. Test ranges are disjoint, ordered inclusive byte offsets. The optional observer receives each token as the single pass over the source reaches it (punctuation one byte at a time, when asked for), for caller-owned token policies; no scan retains a public token array, and observing changes no fact. Invalid literals, allocation failure and input limits are returned errors, never clean coverage.

Semantic callers construct `Project` only when they need ownership, declaration or call facts. Named test targets and literal `@field`/`@hasDecl` references are indexed by the semantic model. The default private-import check uses that same reflection resolver, distinguishes foreign declarations with the same spelling, and withholds dead allegations when required reflection names/receivers remain dynamic. Every untyped declaration literal remains indexed, including unmatched names. Matching names retain conservative lexical liveness, while semantic identity and the required type context remain explicitly unknown. Unresolved types inside pointer/optional/error-union receivers remain required Aegis coverage. Actual lexical aliases of `@import("builtin")` classify positive test arms and negated else arms; an unrelated value named `builtin` does not. Missing mappings remain required semantic coverage rather than blocking literal token facts. Source rejection (including a truncated UTF-8 character literal), absent required lowering and budget exhaustion cannot satisfy a semantic gate.

## Ownership policy and adopters

An ownership policy (raw durability is airlock's, a debug print is the program's logger's) is P006 over the same resolved model every rule reads: what a reference resolves to, configured once by the caller (preflight's default policy for the family), the owning packages named in the entry, any other exception a reasoned suppression. The projection that once offered gantry resolved imports and calls for such policies is gone (0.4.0): gantry reads Zig through the token tier and has no module map to resolve with, so a second resolved walk in gantry would have duplicated P006 under another name. Gantry owns architecture, layers, token-sequence and path policy. Preflight alone selects files/config through gantry's dialect, executes tools and verifies completion, owns layout/format/snippets/tests/CI, and removes its duplicate code predicates after equivalent adoption. G2 provides the glint APIs and exact handoff; neither consumer repo is modified here. Pin dependency order standalone glint → gantry → preflight, without reciprocal build/test pins or disabled closure checks. Embedded public-module tests import no shakedown; fault/allocation drivers belong to the package test root. Preflight adoption is externally owned: pin the published Glint main, use the full module for compiled rules and the completion/build-helper contract, and use `glint_token` for token facts. Glint pins green Preflight `c04e49d329eaa1cb985cdb6ee07f906dd7d84743` and Shakedown `a3db7b9c9b60b76dafe1d6f2fa9aab9a8cde3c95` for its own CI/tests.

Published aegis `586602b1326fd5fda53a1a252dd3f7e1ae5ee359` supplies glint's typed IDs and checked byte counts. The optional G3 pack does not depend on that pin: it recognizes aegis in the checked program at whatever revision the program uses (see [Libraries and published roles](#libraries-and-published-roles)). Untrusted source bytes and bounded-budget leaves are not in this published API; their adoption remains a concrete later type dependency. The pack uses AST/std ZIR heuristics; no verifier is pursued.

## Libraries and published roles

A pack that checks a library's types must know which declaration is the library's. Glint answers by where the library publishes it, never by file bytes, file names or a revision list. `Library(Role)` is plain data: the modules a program imports the library by (`@import("aegis")`, `@import("aegis.id")`), and for each module the public paths that carry a role (`Secret`, `units.Bytes`). Glint finds each module's root in the project's import mappings, walks every path through the library's public namespaces the way a program writes it, and records the declaration it reaches. `RuleContext.role(library, value)` then answers, for any resolved value, which role it plays: a function the library publishes, or a type or instance of the container such a function returns, through pointers, optionals and error unions.

Consequences a pack author can rely on. Any revision that keeps the public names is recognized, wherever its files live and however its bytes change. A copy of the same source under another module name is another library. Two revisions in one project are both recognized. A required member that does not resolve in a module the file imports (a renamed or removed declaration, or an unmapped namespace) is *drift*: `RuleContext.drift` returns it with its reason and import site, and a rule reports it as coverage, so an API change makes a gate incomplete instead of quiet. A member marked `required = false` is simply absent from older revisions. The library's own files, those its roots import, are `RuleContext.inLibrary`: a rule skips them as safe-type internals. A type function is recognized at its calls by the declaration it names; its container is also recognized when its body is one `return` of that container after any comptime checks, and a body with several returns has no single container, so instances of it are not recognized (its calls still are). The library value must outlive the run, because the resolver remembers it by address.

## Published aegis reports (G3)

The optional `AegisPack.rules` uses the public compiled-rule API. The standalone CLI registers
its IDs but never enables them by default; select `--enable A001` (through A006), or pass
report or gate selections and the pack descriptors to `runConfigured`. Explicit gate selection is accepted; an undecided required site still makes execution incomplete.
Generic defaults and the Z012 and D001 reports are unchanged.

Recognition follows lexical declarations and the `aegis` module mapping, through the published names of
`AegisPack.library` (Secret, SecretBytes, Guarded and its Guard, and the id, unit and integer factories, from
the root and from each `aegis.<namespace>` module). It does not infer a secret or lock from a name, and a
type that merely looks like one, or the same source under another module name, is not aegis. A caller maps
the root under `aegis` and, for revisions that build their namespaces as modules, each namespace under the
name its own build gives it. Escaped member spellings use the same identifier decoder as ordinary facts; quoting an operation does not change its obligations. Copies of template/type aliases are excluded.
Operation names (`init`, `acquire`, `deinit`, `raw`, `material`, ...) are the pack's vocabulary for these types: a revision that renames one is not detected by the library, only by the family's own use. A clean run does not establish security, ownership or complete coverage.

| ID/version | Obligation and supported report predicate | Prevention limit |
|---|---|---|
| A001/2 | Recognized secret backing or Guarded lock/data/capability field access must follow exposure and live-guard contracts. | Initialization, publication, intended safe internals and public-only secret components require review. No race/disclosure proof. |
| A002/2 | Direct lexical owner/capability copies require transfer; directly returned expose/value borrows require a lifetime mechanism. | Pointer aliases (a copy of a value that resolves to a pointer or an optional pointer, whatever it points at) and type aliases excluded; a copy whose type or source is declared plain data (primitives, and arrays, slices, pointers, optionals and error unions of them, a literal, a call declared to return one) is decided as no owner; lifetimes, live status, retained callers and field copies are undecided. |
| A003/2 | Local recognized acquisition at block end requires cleanup; direct cleanup twice or address use after cleanup is a local witness. A recognized acquisition is an owner's constructor, a guard's acquisition, or a call to the program's own function whose result is an owner by value. | The walk follows the block's statements, the branches of an `if` and the bodies of `while` and `for` loops: a direct `deinit`, a `defer` of one (after which every exit runs it; one a branch or body defers runs as it ends), member uses, a release before a `return`, a guard's `handOff()`, the owner returned held or carried by value in what is returned (its caller's to release), the owner moved into a local aggregate (a field's value of the struct literal that declares it, the owner named nowhere after), whose obligation is then that local's and is discharged only by giving it to the caller, an `errdefer` release covering the error exits after it (a `try`, a `return error.X`, a `return` of a value of an error set), `@field(owner, name)` read as a member use, and a `catch` or `orelse` handler walked as a branch. A loop's body must bring the owner back to its start in the state it entered in, and the loop goes on in the state its `break`s, failing condition and `else` agree on; one that never ends otherwise ends the path. An exit while held, paths that meet in different states, a jump to an outer loop of the walk, a nested release it does not follow, and any use but a member (an address, a copy, an argument: a transfer or alias) are undecided. No missing-errdefer allegation from proximity. |
| A004/2 | Immediate `raw()` arithmetic/comparison or narrowing/reconstruction cast must retain domain/unit/all-build failure semantics. | Raw boundaries can be intentional; no generic argument equality or raw value taint. Does not prove a mixed clock/domain or integer overflow. |
| A005/2 | SecretBytes.adopt requires full allocator extent/exclusive ownership; explicit end-bounded slice is a review site. | Slice syntax cannot prove allocation extent, provenance, alignment, successful transfer or wipe/free: an adoption is decided only when it takes a whole `alloc(u8, n)` local from the same allocator that nothing uses afterwards (below); every other one records that uncertainty. |
| A006/1 | Recursion reachable from untrusted input needs a depth bound. An entry is a function of the program that takes an aegis `input.Untrusted` parameter or that a program passes to an untrusted value's `parse`; the walk follows calls that resolve to the program's own functions. A cycle it reaches is bounded when one function on it changes a depth it compares: a parameter compared and passed on the cycle as `p + k` or `p - k`, or a field compared and moved by `+=`/`-=`, there or in a function it calls. A comparison with a `.len` is a position in the input, not a bound. | A bound kept further away (an aegis `Budget`, a helper two calls off) is not seen and needs a site reason. A call that does not resolve leaves what it reaches undecided, counted per entry. No claim about stack size; reported, gating only in a hardened profile once admitted. |

A receiver is decided by the type it resolves to: a published aegis type is a candidate, a type
nested in one (a guarded value's guard) stays unknown, and any other resolved type is not a
candidate. Resolution follows declarations, fields, calls and their `!T` results, `try`,
`catch`, `orelse` and `.?`, the payloads `if`, `while`, `switch` prongs and `for` bind, a
`switch` or `if` choosing between types (each branch, a `@compileError` branch left out),
a function returning its `comptime T: type` parameter, a method or field of a container a type
function made, whose parameters read as that call's arguments, and a generic call's result
read with its parameters bound to the call's arguments: a type function returning an
expression, or a result type written in terms of its parameters. `@TypeOf` gives a value's
type; `@typeInfo` reads a type's `.pointer.child`, `.optional.child`, `.array.child`,
`.error_union.payload` and a function's `.@"fn".return_type` and `.param_types[i]`. Inside a
generic function, an `anytype` or `type` parameter is the union of what the project's calls
pass, when every use of the function is such a call and its container is not reached by name
from a module root the project imports (a consumer could call it with anything); a member call
through a path of declarations from a module import reaches only exported names, and one whose
argument count the function cannot take is another function. A use of the function's name as a
value's member, other than a call, is a field and no use of the function: Zig has no bound
methods. A value here is what cannot be a type: an address taken, a `var`, a parameter declared
with a type other than `type`, an `anytype` parameter the program dereferences, a `const` of one
of these, a field of one (unless some container in the project declares a `comptime` field of
that name), and a member assigned to or used as a number. `@call(modifier, f, .{ ... })` passes
the tuple's elements. A call that passes something from a module the build does not have for
its file (`Project.Input.absent`) is not compiled in this build and is left out of the union.
A member of a choice between types leaves out the choices without that member (`void`, a
number, a type that does not declare it): a build in which the access does not compile, and a
receiver that is a pointer to a choice is a pointer to each of its alternatives. `comptime x`
has `x`'s type, and a struct literal with no type where nothing gives it one (a block's value,
an `anytype` argument) is an anonymous struct whose fields are what it gives them. Anything
else stays unknown.
Required unknown receivers and unsupported acquisition/cleanup or adoption sites record undecided coverage. General prevention limits describe the rule boundary; they are not unconditional per-file incompleteness.
Front-end rejection and budget exhaustion still make execution incomplete independently of
findings acceptance. The library's own files, those its `aegis` root imports, are safe-type internals; other source requires the same explicit site policy as consumers. Wiping inline padding
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
The contract covers aegis's published types past the guards too, each by what its source keeps behind its operations and what it owes:

| Types | A001 private state | A002 copy is a second owner | A003 obligation of a local acquisition |
|---|---|---|---|
| `bounded.Array`, `Ring`/`Queue` | `storage`, `used`, `head` | no: a copy is its elements' (A002 does not read the element type) | none |
| `bounded.Buffer`, `RingBuffer`/`QueueBuffer` | `storage`, `gpa`, `maximum`, `used`, `head` | yes | `deinit` |
| `bounded.Limit` | `maximum` | no | none |
| `bounded.Budget` | `ceiling`, `taken` | yes: the copy keeps its own count | none |
| `Budget.Reservation` | `budget`, `amount`, `live` | yes | `release`, `consume` (its amount kept as consumed work), or `moveInto` |
| `own.Owned`, `OwnedIo` | `data`, `state` | yes | `deinit`, or `take`/`moveInto` |
| `own.MustUse` | `data`, `pending`, `live` | yes | `take` or `acknowledge` (its `deinit` checks that one ran) |
| `Shared` | `block`, `live` | yes: a copy with `=` is a handle never retained | `release` (each handle, `create`d or `retain`ed) |
| `handle.Pool`, `SlotMap`, `DenseSlotMap`, `SecondaryMap` | `slots`, `storage`, `primary`, `values`, `keys`, `free_head`, `entries` | yes | `deinit` |
| `handle.Domain`, `id.Counter` | none | yes: both issue the same instances (ids) | none |
| `handle.Index` | a scalar: A004 | no | none |
| `state.Machine.At` | `payload`, `live` | yes | none (a payload leaves by `take` or a transition) |
| `state.Machine.Runtime` | none yet (`state` waits for reactor's backends to type their operations) | yes: one driver owns a machine | none |
| `scope.Table` | `slots`, `free_head`, `used_up`, `open_count` | yes | `deinit` |
| `Table.Scope` | `table`, `index`, `generation` | no | `end` |
| `scope.Ref` | `pointer` (aegis 0.1.14), `slot`, `generation` | no | none |
| `input.Untrusted` | `value` | no | none |
| `sync.Atomic` | `cell` | yes: a second cell | none |
| `Order(...).Context`, `InitContext` | `stack`, `used`, `suspended`, `owners` | yes: a second task context | none |
| `Order(...).Ordered` | `base` | yes | its ordered acquisitions give guards released by `deinit(io)` |
| `secret.Choice` | `bit` | no | none |

An acquisition is any call that gives one of these by value (`budget.reserve(n)`, `shared.retain()`, `table.open()`, `Buffer(T).initAllocated(...)`), not only one named `init`. A call that gives a type aegis declares and the contract does not list (a guard's `Handoff`) owes nothing: the contract names every type that carries an obligation. A runtime machine's `state` is its backing field (reactor 0.7.0 types its backends' operations, so their `o.state` resolves). A name a backing field shares with a method is the method where the program calls it, since no backing field holds a function. `TaskIdentity` stays outside the contract: the caller issues identities (by `@enumFromInt` or otherwise), copies and compares them, and no aegis operation guards one. `err.PublicSource` is made by `classify`, whose reason is the review: A001 finds a struct literal of it outside aegis by the type the literal takes from its place (a declaration's written type, an assignment's target, a call's parameter, a made container's method read with its arguments, its function's result, a typed literal's field or array's element, `@as`, through groupings, branches and labeled breaks). A literal that names exactly its fields and whose place does not resolve is undecided.

A005 decides an adoption of a whole byte allocation: the allocation is a local initialized by `a.alloc(u8, n)` (through `try` or `catch`) from the allocator the adoption is given, written the same way, and no use of the local follows the adoption or waits in a `defer` or `errdefer`. The extent is then the allocation's and the alignment a byte's, and the owner holds it alone; every other shape stays a review site.
Aegis scalar ABI guarantees cover non-exhaustive enums over 8–64-bit and native-size integers;
128-bit values remain Zig-only and are not included in that C ABI guarantee.
