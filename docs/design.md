# glint design

glint is a linter for Zig. It reads source with Zig's own parser and lowering (std.zig.Ast and AstGen/ZIR),
resolves what each reference names, and reports two kinds of rule. Lines marked **Pending** wait on a branch
that is still being merged; their wording is not final.

## What glint claims

A rule is one of two kinds, and says which:

- **Ban.** A construct is not used outside a declared seam. The construct is named by its syntax, or by the
  declaration a reference resolves to. Every site is a finding: there is no excuse, no proof that a site is
  harmless, and no analysis to fool. A ban must never miss, and it reads nothing but its construct, so it
  cannot. A reference that does not resolve, in a file the ban applies to, is a finding ("cannot show this is
  not X") where its name belongs to no other declaration the program reaches, std's included. An enum literal
  or a struct-init label never spells a declaration, and a computed `@field` spells nothing: over a governed
  holder it is the reflection finding, once.
- **Hygiene.** Dead code, unused imports, naming, length, deprecations. A hygiene rule reports only what it is
  certain of and claims nothing about what it does not report. A miss harms nobody; a wrong report is the only
  defect.

A run ends in one of three ways: findings, reports, or a run error. There is no "undecided" result and no
partial pass: what glint cannot read is a run error that names the file and what to do (below), never a site
counted as unknown. Soundness is relative to the claim: every claim glint makes is one it can decide.

## Who defends what

| Layer | Catches | How |
|---|---|---|
| ReleaseSafe | bounds, overflow, `unreachable`, null, a bad enum or union access | runtime panic |
| aegis | use after free, lock misuse and order, ownership, must-use results, hostile input, secrets | types that check themselves |
| fuzzing, the testing allocator | panics on hostile input, leaks | each package's tests |
| glint | going around aegis; a raw construct where a package declares its type as the answer; operations Zig leaves unchecked; hygiene | bans and hygiene rules |

## Rules

Each construct list is closed: it is the whole set of forms the rule reads. Builtins are checked against the
Zig 0.17 langref's list, and syntax against its grammar. "Test code" means lexically inside a `test` block, or
an input classified as a test (the configuration's `test_inputs`, or the caller's classification: preflight's by file name). Nothing else counts: a file or a helper reached only from
tests is production code.

A rule marked "off by default" runs only where a setting or `--only` names it, under every profile. Every other
rule below runs under the `reviewed` profile; the bare `core` profile runs Z003 and Z013 only, and `none` runs
nothing unasked. The configuration keys a rule reads are named in its row with their defaults:
`max_line_length` (Z024), `max_function_lines` (P003), `max_stack_array` (Z038), `max_parameters` and
`max_nesting` (P013).

### glint's own rules

| ID | Kind | Claim and construct list |
|---|---|---|
| Z001 Z005 Z006 Z009 Z014 Z031 Z032 | hygiene | Naming over known kinds. A name whose kind does not resolve is silent; a call of a function declared to return `type` names a type. An established external ABI name is kept. |
| Z003 | hygiene | Input that std's parser or lowering rejects. |
| Z024 | hygiene | A line longer than the configured byte length (`max_line_length`, default 100). |
| Z034 | hygiene | Two binary operators the next Zig refuses to order without parentheses (a product and a remainder, two bitwise operators, arithmetic and bitwise, `and` and `or`, `orelse` or `catch` with any other), or a chained shift or remainder. The fix parenthesizes as 0.17 groups. |
| P003 | hygiene | A function longer than the configured line count (`max_function_lines`, default 120). An exception (`function_exceptions`) names a function and its reason; one naming no function is a run error. |
| Z011 | hygiene | A call whose callee resolves to a declaration whose doc comment begins "deprecated" or "this function is deprecated". A choice of callees counts only when every alternative is deprecated. An unresolved callee is silent. |
| Z012 | hygiene | A type written by name in a public surface signature (parameter, return, a `pub const` annotation, a surface field) that resolves to a private container written in place with no public alias. The walk goes through parentheses, `?`, `E!`, pointers, slices, arrays, and a function prototype or container written in place. Calls, made types, comptime choices, builtins and inferred types are not read. |
| Z013 | hygiene | A private `const X = @import("...")` whose name the file spells nowhere else: no identifier, member token, `.X` literal, or `@field` string. A file holding a computed `@field` name reports none. |
| Z016 | hygiene | A call resolving to std's `debug.assert` whose argument, as written (parentheses and `comptime` stripped), is `a and b`. Nothing is followed. |
| D001 | hygiene | A private function or variable at file or container level whose name its file spells nowhere outside its own declaration. Any spelling is a use. A file holding a computed `@field` name reports none. A declaration that only dead code names is used. |
| Z026 | ban | A discarded error needs a written reason. An error handler (`catch`, an `if`'s or a `while`'s `else \|e\|`) whose body is empty: a block of empty statements (`{}`, a bare `break` to its own label, `_ = X` with no call), `void{}`, `@as(void, …)` of an empty one, an `if` or `switch` whose every branch is empty, `return`/`continue`/`break` with no operand. Also `catch unreachable`, and a handler that only traps: a block whose one statement is `unreachable`, a `switch` whose every prong is. A handler that returns a value, or calls anything, is not empty; this rule does not judge what it does with the error. `orelse unreachable` is not Z026's: a null is no error, and the safe build traps it. Test code is exempt. |
| P005 | hygiene | A reference that resolves to std's `debug.print`, outside test code, on the `replaces` engine. A reference that does not resolve is silent. |
| P006 | ban | A reference that resolves to a declaration (or an extern symbol) the project's `disallowed` list names, outside the packages the entry names as owners, on the `replaces` engine. An entry that resolves to nothing is a run error. |
| P007 | ban | An operation Zig leaves unchecked, outside a seam, in production code: inline `asm`; `@setRuntimeSafety` off in a build that keeps the checks, or on a value the build mode does not decide; the pointer conversions no build checks (`@ptrCast`, `@alignCast`, `@constCast`, `@volatileCast`, `@ptrFromInt`, `@fieldParentPtr`); an `extern` declaration and `@extern`; `noalias`; `@setFloatMode(.optimized)`; arithmetic on or indexing of a many-item or C pointer; std's `mem.bytesAsValue` and `mem.bytesAsSlice`; and any member of `std.c`, `std.os.linux` or `std.os.windows`. A chain of casts written one inside another is one site, the outermost. Not read: the interface idiom, `@fieldParentPtr` with the `@alignCast` around it, and `@ptrCast`/`@alignCast` from `*anyopaque` to a single-item pointer; a cast to a slice or a many-item pointer stays a site. What the program runs only as it compiles is not read. (Was A019.) |
| P008 | ban | Two or more identifying integers of one type meeting in one public signature or one public struct, where nothing keeps one from standing for the other, read from the shape alone. Two names are one integer when their types resolve to it, or are spelled alike and are an integer whatever the build chooses. A type that does not resolve, or a choice that may meet the other's, is a finding. (Was A016.) |
| P009 | hygiene | A pointer into a function's own frame carried out by its `return`: the address or a slice of a local, in a returned literal or through a local alias. Comptime frames are not read, and a `const` whose value is compiled in is static memory: a literal, `comptime x`, a comptime parameter, a file or container declaration, a local const, arithmetic on those, or an inline call with such arguments. Only an escape it shows is reported: a value whose reach is not read (its address handed to a callee whose stores are not known, a value that does not resolve, more aliases than are followed) is silent, never a report. (Was A014.) |
| Z035 | hygiene | Two operands written alike: `a OP a` for `and`, `or`, `-`, `^`, `|`, `&`; for a comparison only where `a`'s declaration writes an integer or `bool` type (a float's `x != x` is its NaN test). |
| Z036 | hygiene | An `if` / `else if` chain repeating an earlier condition token for token, or an `if` whose `else` body is written as its `then` body. |
| Z037 | hygiene | Arithmetic done narrow and then widened: `@as(u64, a * b)`, `@as(u64, a << n)`, `const x: u64 = a * b`, where the operands' declarations write narrower integer types. |
| Z038 | hygiene | A local `var [N]T` (N a literal or literal arithmetic, T a primitive of stated size) over the configured byte limit (`max_stack_array`, default 64 KiB): the frame may not fit a thread's stack. |
| Z039 | hygiene | A comparison fixed by its operand's type: an unsigned value (a slice's or array's `len`, or a name whose declaration writes an unsigned type) compared with a written `0` by `<` or `>=`. |
| Z040 | hygiene | `std.testing.expect(a == b)` where a side is a value literal (a number, character, string, `null`, `true` or `false`): `expectEqual` prints both values. Where exactly one side is a literal, the fix rewrites it to `expectEqual(literal, other)`. An enum literal, or no literal side, is not read: `u == .tag` reads a tagged union's tag, which `expectEqual` does not compile. `!=` is not read. |
| Z041 | hygiene | A partial read's or write's count discarded: `_ = X(...)` or `_ = try X(...)` where every callee is one of std's functions that may move fewer bytes than asked (a closed list against Zig 0.17's std). |
| Z042 | hygiene | `expectEqual` with the expected literal written second. |
| Z043 | hygiene | A loop that leaves on its first pass. |
| Z044 | hygiene | A function that recurses before anything can stop it. |
| Z045 | hygiene, off by default | A public declaration without a doc comment, on the public surface: the run's module roots and the `pub` import chains from them. |
| Z046 | hygiene, off by default | A field or tag not named as the style guide names it. |
| Z047 | hygiene | A condition written as a literal: `if (true)`, `if (false)`, `while (false)`, through parentheses. `while (true)` and comptime-known names are not read. |
| Z048 | hygiene | A float compared with `==` or `!=` to a decimal literal its type cannot hold exactly (`x == 0.1`, `x` declared `f64`). |
| Z049 | hygiene | A comparison with NaN: an operand that is a call of std's `math.nan`, under any comparison operator. |
| Z050 | not built | Not built: std's `Io.Condition.wait` loops past spurious wakeups itself, so a wait outside a loop is not certainly wrong. |
| Z051 | hygiene | A loop counter narrower than its bound: `while (i < n) : (i += 1)` where `i`'s declaration writes a narrower integer type than `n`'s. |
| Z052 | hygiene | `const x: T = undefined;` read anywhere but inside `@TypeOf`. |
| Z053 | hygiene | An `errdefer` in a function whose written return type cannot be an error union (a primitive, a pointer, an optional, an array). |
| Z054 | hygiene, off by default | In `build.zig`, a module with a hard-coded `.optimize` or `.target` where the script also reads `standardOptimizeOption` or `standardTargetOptions`. |
| Z055 | hygiene, off by default | A parameter written `anytype` in a public function on the public surface. |
| Z056 | hygiene, off by default | An `if` or `else` body written `{}` with nothing inside, not even a comment. Loops and `switch` prongs are not read. |
| P013 | policy metric, off by default | A function with more parameters than `max_parameters` (default 7), or deeper `if`/`while`/`for`/`switch` nesting than `max_nesting` (default 5). |
| P010 | ban, off by default | An unwrap that can trap needs a written reason: `.?` and `orelse unreachable`, outside test blocks. |
| P011 | ban, off by default | `undefined` outside a test needs a written reason. |
| P012 | ban, off by default | Debugging left in the code needs a written reason: `@breakpoint()`, and a `@panic` whose message marks it unfinished. |

### Rules a package declares

A package declares its rules in `lint_rules` (below), and they join a run wherever the program reaches the
package, each on by its own `.default`. glint names no package and holds no package's rules: aegis's are
entries of the vocabulary, under the ids aegis declares. As aegis declares them today:

| ID | Kind | Reads | Construct |
|---|---|---|---|
| A001 | ban | governed | Any touch of a governed type's internal field, a struct literal naming one, and any cast or reflection over a governed type, outside aegis. |
| A004 | hygiene | exits | An exit's result (`raw` on int.Checked, Saturating, Ranged, id.Id, and units' Count, Bytes, Bits, Duration, Instant) given straight to arithmetic, a comparison or a narrowing cast. |
| A007 | ban | replaces | std's Io.Mutex, Io.RwLock, Io.Condition and futex functions, Io.Event, atomic.Value and the atomic builtins, atomic.Mutex, each with aegis's answer. Io.Semaphore has no answer and is not banned. |
| A008 | ban | replaces | crypto.secureZero, timing_safe.eql and compare, and every key type by its declaration (a reference ban: even `Secret(KeyPair)` names it). |
| A009 | ban | replaces | The input seam: std's input sources (Io.Reader's reading functions and `buffer`, File's and Dir's reads, process.run, posix.read, aegis's own.readFile) called only in a declared input seam. |
| A011 | ban | replaces | Io.Duration's and Io.Timestamp's raw-integer functions and fields, and std.time's `*_per_*` constants. |
| A012 | ban, off by default | replaces | A std container that grows without a stated limit, where the project selects it: bounded's types hold a capacity the program states. |
| A013 | ban | replaces | std's `debug.assert`, answered by aegis's assert. |
| A015 | ban | replaces | Io.File, Io.Dir, net.Stream, net.Server and process.Child held by value in a struct field. |
| A021 | ban, off by default | replaces | An unordered acquisition on aegis's guards, where the project selects ordering. |

### Removed and renamed rules

A configuration or a suppression naming a rule 0.8 removed is refused, with what to write instead. The table
is `Rule.removed_rules` (`glint.RemovedRule`, `glint.removedRule`); no removed id is an alias.

| IDs | Now |
|---|---|
| A002, A003, A005, A006, A010, A017, A018, A020 | Removed: remove them. aegis's owners, the testing allocator and fuzzing carry what they checked. |
| A001, A004, A007, A008, A009, A011, A012, A013, A015, A021 | aegis's: declared in its `lint_rules`, rules wherever the program reaches aegis. |
| A014, A016, A019 | Renamed P009, P008 and P007. |

Any other name no rule of the run has is "not a rule glint has".

## The package vocabulary (version 2)

`pub const lint_rules = .{ .version = 2, .include = .{...}, .rules = .{...}, .governed = .{...}, .replaces = .{...} };`
is a struct literal in a module root. glint reads it from its syntax, and resolves every reference in it by
declaration.

- `.rules`: `.{ .id, .name, .kind = .ban | .hygiene, .reads = .governed | .exits | .replaces, .default, .purpose }`.
  The package names its own ids. A run refuses two packages that declare one id.
- `.governed`: `.{ .type = T, .internal = .{ .field, ... }, .exits = .{ .member, ... } }`. `T` is a declaration,
  or `.{ .generic = F, .member = .Name }` for every instance of a type function's member. Every internal field
  is named `<package>_<name>` (aegis's `aegis_state`), so a reference glint cannot resolve still names the field;
  one without the prefix is a malformed entry in the declarer. A type function's forms may differ (one returns
  `Keyed` or `Indexed` by an option): each name is a member of at least one form and is governed on every form
  that has it; a name on no form is unresolved, and one some form holds as another kind is malformed.
- `.replaces`: `.{ .rule, <target>, .held = .field (optional), .with, .drop_in (optional), .why }`. The target is exactly one of:
  - `.decl = D`;
  - `.members = C, .except = .{...}` (every function declared directly in `C`, so a new one is caught);
  - `.field = .{ .type, .name }`;
  - `.builtin = .@"@name"`;
  - `.symbol = "name"` (an extern's link name).

  `.held = .field` counts the target only as a struct field's type held by value. The declaring package itself
  may use what it replaces.

  `.drop_in = D` names the one of `.with` that takes a call of the target one for one: its parameters are the
  target's, each type as written, then at most one `comptime []const u8`, which `--fix` fills with the call's
  arguments as written (`std.debug.assert(n < 9)` becomes `assert.invariant(n < 9, "n < 9")`). Each site then
  carries a fix: the call, or a private alias of the target together with every call through it, and an import
  of the package where the file has none, under the module name the package's other files use. Any other answer
  is a malformed entry: no fix is made from a guess at how the answer is called.

Version 1 (`.roles`, `.pairs`, `.door`, `.deprecated`, the old `.replaces`) is read no more. A part of
`lint_rules` glint cannot read is a malformed entry where it is written, and the declaring package's run is a
run error. In a consumer, an unresolved reference inside a banned file is a finding.

## Configuration, seams and suppression

A project's `glint.json` holds its seams, test inputs and code options, the one home of each: preflight passes it
to glint unchanged, and preflight's own `glint` block holds only the rule levels (`rules`). On the command line
`glint.json` also holds the profile and levels:

```json
{
  "profile": "reviewed",
  "rules": [{ "id": "Z026", "level": "gate" }, { "id": "P011", "level": "report" }],
  "seams": [
    { "file": "src/uring.zig", "rules": ["A007", "P007"], "reason": "kernel-shared ring words" },
    { "module": "src/backend/", "rules": ["P007"], "reason": "the backends are the runtime's OS seam" }
  ],
  "test_inputs": [{ "path": "tests/*.zig" }, { "module": "fixtures/" }]
}
```

A **seam** names a file, a glob or a directory, the rules it holds, and a written reason; it is declared in the
configuration, never inline. The report counts each seam's sites, so a seam cannot grow unseen, and a seam is
stale where its rules ran and it held nothing. **`test_inputs`** names the inputs read as test code, by path
glob or directory, for every caller: the command line and preflight alike.

A single site is answered by one comment, inline or on the line before:

```zig
// glint-ignore: Z026 -- the cache is advisory; a failed write leaves the old entry
cache.store(key, value) catch {};
```

It names one or more rules (`// glint-ignore: P007, A007 -- <reason>`), each covering one site on its line, and
needs a non-empty reason. A malformed comment is reported where it is written, and every suppression is
counted. There is no other form: the `// aegis: <reason>(<rule>): <why>` escape is malformed, and `--fix`
rewrites it into a `glint-ignore` naming the rules it covers (an escape that names none takes the rules a record
of an earlier run lists, `--escapes-before`; with no record it is left for its owner to name). A suppression
naming a rule under the name 0.7 gave it takes today's (A019 is P007, A016 P008, A014 P009); a rule 0.8 removed
(A002, A003, A005, A006, A010, A017, A018, A020, and 0.7's A012, another check than aegis's) is dropped from it,
and one naming none left goes. `--fix` also rewrites 0.7's `// unreachable: <why>`, at a `catch unreachable` or
alone on the line above it, into `// glint-ignore: Z026 -- <why>`, except where that line holds a second such
site, which one suppression cannot name. No fix writes a suppression a site did not already have.

## Model and run

`Project.init` takes explicit source bytes, labels, test classification and import edges; the engine opens no
paths and never runs the checked project's build or comptime code. Facts resolve references and calls by
declaration; what they cannot resolve stays unknown, and each rule's kind says what an unknown means (a finding
for a ban, silence for hygiene). Reports are text, JSON version 1, or SARIF 2.1.0, ordered deterministically.

**Run errors.** glint refuses to run, naming what to fix, where it cannot read what it was given:

- a file std's parser or lowering rejects: the file and the error;
- an import no module mapping names: the import, the file, and how to map it (`--module NAME=FILE`, or the
  build's module graph through preflight, which maps the options modules, the roots a WriteFiles step embeds and
  the generated roots by their text); an import under a comptime branch the build does not take is nothing;
- a configuration glint cannot read, a rule it does not have (with the removed-rule table's answer), a P003
  exception naming no function, a P006 entry resolving to nothing.

Exit 0 means a completed run with no findings, 1 a completed run with findings, and 2 a run error or an
argument, input, tool, output or cancellation failure. A `--result` record binds an invocation id, the exit
class and the exact flushed output (`Completion.verify`).

## What glint does not claim

- That a program is safe, cannot panic, or keeps any property at run time. ReleaseSafe, aegis's types, the
  testing allocator and fuzzing carry those.
- Anything about what the program computes: no flow, no ranges, no lifetimes beyond P009's shape, no taint.
- Anything about generic or comptime code beyond its syntax: glint never evaluates comptime code or runs the
  build.
- Anything about a module no CI target provides: glint reads the modules the run maps. A file only another
  target's build reaches is linted where that target's modules are mapped, and nowhere else.
- That a hygiene rule's silence means the construct is absent. Only a ban's silence is a claim.
- That a seam's or a suppression's reason is true. glint counts them; review judges them.

## What was removed, and where it lives

The proof engines left in 0.8.0: Taint, Range, Bounds, Proof, DangerFlow, the release walks, Escapes beyond
P009's shape, Undefined's flow, ParentPointer's proofs, Summary, and the compiled-facts reader and exporter.
So did the compiled aegis pack and the rules only the engines served (the table above). All of it is on the
`strict-1029b` branch, unchanged, as the 0.7 line left it. Per-instance compiler facts, if ever wanted again,
are their own project.
