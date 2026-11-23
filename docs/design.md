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
| Z012 | hygiene | A type written by name in a public surface signature (parameter, return, a `pub const` annotation, a surface field) that resolves to a private container written in place with no public alias. The walk goes through parentheses, `?`, `E!`, pointers, slices, arrays, and a function prototype or container written in place. Calls, made types, comptime choices, builtins and inferred types are not read. The public surface is what the roots of the modules the package exports reach through `pub` declarations (a public alias's target included, a private alias exporting nothing; preflight states the roots, the command line `--exported FILE`): a container a private function makes, a file reached only through a private alias or a test block, and every file-level declaration when no root is stated, say nothing. |
| Z013 | hygiene | A private `const X = @import("...")` whose name the file spells nowhere else: no identifier, member token, `.X` literal, or `@field` string. A file holding a computed `@field` name reports none. |
| Z016 | hygiene | A call resolving to std's `debug.assert` whose argument, as written (parentheses and `comptime` stripped), is `a and b`. Nothing is followed. |
| D001 | hygiene | A private function or variable at file or container level whose name its file spells nowhere outside its own declaration. Any spelling is a use. A file holding a computed `@field` name reports none. A declaration that only dead code names is used. |
| Z026 | ban | A discarded error needs a written reason. An error handler (`catch`, an `if`'s or a `while`'s `else \|e\|`) whose body is empty: a block of empty statements (`{}`, a bare `break` to its own label, `_ = X` with no call), `void{}`, `@as(void, …)` of an empty one, an `if` or `switch` whose every branch is empty, `return`/`continue`/`break` with no operand. Also `catch unreachable`, and a handler that only traps: a block whose one statement is `unreachable`, a `switch` whose every prong is. A handler that returns a value, or calls anything, is not empty; this rule does not judge what it does with the error. `orelse unreachable` is not Z026's: a null is no error, and the safe build traps it. Test code is exempt. |
| P005 | hygiene | A reference that resolves to std's `debug.print`, outside test code, on the `replaces` engine. A reference that does not resolve is silent. |
| P006 | ban | A reference that resolves to a declaration (or an extern symbol) the project's `disallowed` list names, outside the packages the entry names as owners, on the `replaces` engine. An entry that resolves to nothing is a run error. |
| P007 | ban | An operation Zig leaves unchecked, outside a seam, in production code: inline `asm`; `@setRuntimeSafety` off in a build that keeps the checks, or on a value the build mode does not decide; the pointer conversions no build checks (`@ptrCast`, `@alignCast`, `@constCast`, `@volatileCast`, `@ptrFromInt`); an `extern` declaration and `@extern`; `noalias`; `@setFloatMode(.optimized)`; arithmetic on, indexing or slicing of a many-item or C pointer (a slice's `.ptr` is one); std's `mem.bytesAsValue` and `mem.bytesAsSlice`; and any member of `std.c`, `std.os.linux` or `std.os.windows`. A chain of casts written one inside another is one site, the outermost. Not read: the interface idiom, `@fieldParentPtr` bare or with the `@alignCast` around it, one claim in either spelling: neither proves the field pointer was taken from that parent, the `@alignCast` only adds a runtime check where Zig already proved the alignment, and it is std's own interface idiom, which glint cannot tell from a misuse; and `@ptrCast`/`@alignCast` from `*anyopaque` to a single-item pointer; a cast to a slice or a many-item pointer stays a site. What the program runs only as it compiles is not read. (Was A019.) |
| P008 | hygiene | Two or more identifying integers of one type meeting in one public signature or one public struct, where nothing keeps one from standing for the other, read from the shape alone. Two names are one integer when their types resolve to it, are spelled alike and are an integer whatever the build chooses, or one is an integer in every build that the other's per-build choice includes (both are it in the build that picks it). Not caught: ids whose type a caller binds (a `comptime T: type` parameter's, an `anytype` one's: `generic`), a type that does not resolve, and two per-build choices whose parts meet (each build chooses on its own). (Was A016.) |
| P009 | hygiene | A pointer into a function's own frame carried out of the call in one statement: `return &local`, `return &local.f` or `&local[i]` of a held value, or a slice of a local array; and such an address assigned straight to a container's variable or a field of a pointer parameter, or given to `@atomicStore`, unless a defer of the function assigns that place again or names the local after. A local is a runtime `var` the function declares. Nothing is followed: an alias, a pointer local, a callee, a constant or a comptime frame is silent, never a report. (Was A014.) |
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
| Z057 | ban | A compound assignment (`+=`, `-=`, `*=`, `\|=`, `<<=` and the rest) whose right side calls a function handed the place the left side updates: Zig loads the left side before the call, so what the call writes there is lost (`at.* += (try f(bytes, at)).bytes`). The left side is a name followed by field accesses, dereferences and indexes whose index runs no code; a call is handed it when an argument is `&q` for the left side or a place it is written through, a pointer the left side dereferences, or the name it starts with where that name's declaration writes a pointer type and the left side reaches through it. Reported whether or not the call writes there. Not read: an alias the syntax does not show (a pointer copied into another name or held in a field, a method's receiver) and a plain `x = x + f(&x)`. |
| P013 | policy metric, off by default | A function with more parameters than `max_parameters` (default 7), or deeper `if`/`while`/`for`/`switch` nesting than `max_nesting` (default 5). |
| P010 | ban, off by default | An unwrap that can trap needs a written reason: `.?` and `orelse unreachable`, outside test blocks. |
| P011 | ban, off by default | `undefined` outside a test needs a written reason. |
| P012 | ban, off by default | Debugging left in the code needs a written reason: `@breakpoint()`, and a `@panic` whose message marks it unfinished. |
| P014 | ban | Standard output or standard error written through a positional writer: a call whose every callee is std's `Io.File.writer`, whose receiver is a call whose every callee is std's `Io.File.stdout` or `Io.File.stderr`, as written or as the value of a `const` in the same file it names, through parentheses, `try`, `orelse`, `catch` and an `if`'s or a `switch`'s results. A receiver that is a stream in one branch is reported. A `var`, a parameter and a field are not followed. Test code is read too. The answer is `writerStreaming`, or ensign's streaming stdout and stderr. |

### Rules a package declares

A package declares its rules in `lint_rules` (below), and they join a run wherever the program reaches the
package, each on by its own `.default`. glint names no package and holds no package's rules: aegis's are
entries of the vocabulary, under the ids aegis declares. As aegis declares them today:

| ID | Kind | Reads | Construct |
|---|---|---|---|
| A001 | ban | governed | Any touch of a governed type's internal field, a struct literal naming one, and any cast or reflection over a governed type, outside aegis. Reflection is a reflective builtin, or a governed type or value named to one of std's readers of a value (fmt print, json and zon stringify, autoHash, expectEqual, mem.eql, asBytes, toBytes, meta.eql) or makers of a type (mem.zeroes, bytesToValue, meta.fields and the rest), two tables in `Governed.zig`; any other std call is none. |
| A004 | hygiene | exits | An exit's result (`raw` on int.Checked, Saturating, Ranged, id.Id, and units' Count, Bytes, Bits, Duration, Instant) given straight to arithmetic, a comparison or a narrowing cast. |
| A007 | ban | replaces | std's Io.Mutex, Io.RwLock, Io.Condition and futex functions, Io.Event, atomic.Value and the atomic builtins, atomic.Mutex, each with aegis's answer. Io.Semaphore has no answer and is not banned. |
| A008 | ban | replaces | crypto.secureZero, timing_safe.eql and compare, and every key type by its declaration (a reference ban: even `Secret(KeyPair)` names it). |
| A009 | ban | replaces | The input seam: std's input sources (Io.Reader's reading functions and `buffer`, File's and Dir's reads, process.run, posix.read, aegis's own.readFile) called only in a declared input seam. |
| A011 | ban | replaces | Io.Duration's and Io.Timestamp's raw-integer functions and fields, and std.time's `*_per_*` constants. |
| A012 | ban, off by default | replaces | A std container that grows without a stated limit, where the project selects it: bounded's types hold a capacity the program states. |
| A013 | ban | replaces | std's `debug.assert`, answered by aegis's assert. |
| A015 | ban | replaces | Io.File, Io.Dir, net.Stream, net.Server and process.Child held by value in a struct field. |
| A021 | ban, off by default | replaces | An unordered acquisition on aegis's guards, where the project selects ordering. |

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

A `lint_rules` of a version other than 2 is read as no rules, its version a finding in the declarer. A part of
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
counted. There is no other form: any other comment is a comment. A suppression naming a rule glint does not
have is malformed. `--fix` drops from a suppression each rule that ran and met no site under it, and removes one
naming none left. No fix writes a suppression a site did not already have.

## Model and run

`Project.init` takes explicit source bytes, labels, test classification and import edges; the engine opens no
paths and never runs the checked project's build or comptime code. Facts resolve references and calls by
declaration; what they cannot resolve stays unknown, and each rule's kind says what an unknown means (a finding
for a ban, silence for hygiene). Reports are text, JSON version 1, or SARIF 2.1.0, ordered deterministically.

**Unknowns.** What Facts cannot resolve carries its reason, and the reason says whether the run is incomplete
(`failure`: glint's own, on code the run holds whole) or the value is outside every ban's language by
definition (`outside`: a ban covers resolved callees and types). A ban counts both per rule, never as a verdict;
a failure is reported by name.

| Reason | Meaning | What it covers |
|---|---|---|
| `invalid_front_end`, `missing_mapping` | failure | A file std's parser or lowering rejects; an import no mapping names (both run errors). |
| `unresolved`, `unsupported`, `cycle`, `budget` | failure | A reference glint does not resolve, a construct it does not read, a query that meets itself, a budget spent. |
| `generic` | outside | A value a type or `anytype` parameter decides where each binding is made: a consumer's call, or none in the project. What is read of it (its information, its members, a call through it) stays generic. A binding made through the function itself is generic, never a cycle. |
| `comptime_dependent` | outside | A value only compile-time evaluation decides, which glint never runs: a type `@Struct`, `@Union` or `@Tuple` builds from a computed list (a list written out, or every field one type, is read); a `var` whose given values are all types; a member read off a computed type. |
| `zig_own` | outside | The compiler's per-build `builtin` and the `root` std reads. |
| `computed_import` | outside | An `@import` whose name is computed as it compiles. |
| `absent` | outside | Code this build does not compile: an import of a module the build does not have; a parameter no function of a reflected choice has; an element past the end of a tuple literal; a switch prong's capture naming no kind the subject may be; `field_types` of a type with no field; a part of a choice Zig refuses the access on. |
| `external` | outside | Bytes a build step makes (translate-c's output, a Run step's file), and a call through a pointer `@extern` gives: foreign code glint never holds. The `extern` declaration itself is P007's, governed by its seams. |
| `erased_callee` | outside | A call through a function value whose targets the program has only as it runs: one a field, a parameter or a `var` holds (or a capture of one), or a call's result whose functions are not read. A `const` naming functions, a call each of whose returns names functions, and a call on a receiver a `const` holds whose initializer is a literal of named functions (`StaticStringMap.initComptime(.{ .{ "x", f }, ... }).get(k)`) are the choice of those functions, each read as a callee. |

**Soundness suite.** Each rule's `expected.zon` lists the cases glint does not pass yet (`open`) and, for a
hygiene rule, the holes its stated scope leaves out (`outside`): such a hole must stay clean, and one that starts
flagging fails the run until the list says so. The rule's row above says why it is silent there.

**Run errors.** glint refuses to run, naming what to fix, where it cannot read what it was given:

- a file std's parser or lowering rejects: the file and the error;
- an import no module mapping names: the import, the file, and how to map it (`--module NAME=FILE`, or the
  build's module graph through preflight, which maps the options modules, the roots a WriteFiles step embeds and
  the generated roots by their text); an import under a comptime branch the build does not take is nothing;
- a configuration glint cannot read, a rule it does not have, a P003
  exception naming no function, a P006 entry resolving to nothing.

A module whose bytes the configuration holds (sources, copied files, a WriteFiles step's contents, an options
module) is read and linted; a module whose bytes exist only after a build step runs (translate-c's output, a Run
step's output file) is external (`Project.Input.external`, `--external NAME`): its import resolves to it, what is
read through it is unknown, it is never linted, it is no run error, and a ban still reports a name spelling one
of its targets as it does an unresolved reference.

Exit 0 means a completed run with no findings, 1 a completed run with findings, and 2 a run error or an
argument, input, tool, output or cancellation failure. A `--result` record binds an invocation id, the exit
class and the exact flushed output (`Completion.verify`).

**Front end.** Every Zig file goes through the installed Zig's std.zig.Ast and AstGen, the lowering
`zig ast-check` uses, and glint's model is built over the ZIR with the AST's spans and comments kept. A file std
cannot lower is a run error, and so is one whose lowering std would crash on: a float literal
`std.zig.parseNumberLiteral` accepts and `std.fmt.parseFloat` refuses (`0x.p1`) is refused before AstGen sees it.
A `.zon` input (`Project.Input.kind`, set by the CLI from the extension and by preflight from the module graph)
is parsed as ZON and never lowered: it is data, no rule runs on it, and an `@import` of it resolves to its root
expression, read by the readers an untyped `.{ ... }` literal written in place goes through. A declared type
gives it its type (`const k: K = @import("k.zon")` is a `K`).

**Test code** is lexical: inside a `test` block, or an input `test_inputs` names. A file or helper reached only
from tests is production code.

**Fixes.** `--fix` applies only a fix that follows from the site alone: Z034's parentheses, a package
replacement's `.drop_in` call, and a suppression's rule that met no site dropped. No fix proves anything.

**Speed.** No numeric target: `bench/` is compiled by CI and run by hand, and no timing is gated.

## Who owns what

| Concern | Owner |
|---|---|
| Parsing, scopes, import and call resolution, test context; code rules (bans, hygiene, a package's declared rules); assertion and function metrics | glint |
| Dependency, layer, ownership and cycle graphs, the path dialect, other languages | gantry, over glint's references |
| File selection, family rule levels, running the tools, the hardened jobs, the gate | preflight, through gantry's path dialect |

The production edges are glint → aegis → std, gantry → glint (lazy, its Zig front end), and preflight → gantry
and glint. glint has no edge to gantry or preflight, its CLI runs without either, and it names no package: a
package declares its rules in `lint_rules` and glint reads them. preflight fails a run on the bans a project
selects; hygiene reports, and a project may gate it. There are no blanket warnings-as-errors.

**Prior art.** From TigerStyle and its tidy: dead private declarations (D001, with Z013 the import case),
disallowed declarations as one rule with a reason and a replacement (P006), split compound assertions (Z016),
function length (P003); not its bans on recursion, `usize` or allocation after startup, assertion counts as a
gate, or unit suffixes (aegis's units carry the unit in the type). From Clippy: confidence apart from severity,
which is the two kinds. From zlint: scopes, references and node links over the AST.

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
