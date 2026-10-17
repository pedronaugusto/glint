# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Added

- A003 follows an owner through loops: a `while` or `for` loop's body must bring the owner back to its start (its end and each `continue`) in the state it entered in, and the loop goes on in the state its ways out agree on (each `break`, its condition failing, its `else`); a loop that never ends otherwise (`while (true)`) ends the path, as a release a body defers runs at the end of each pass. A guard released and acquired again around a wait, and one returned from inside a loop, are decided this way (reactor's lanes and spare threads); ways out in different states, and a jump to an outer loop of the walk, stay undecided.
- A003 reads an owner returned held (`return held`) as its caller's to release, and the caller's local as an acquisition: a call to a function of the program's own whose result is an owner (not a pointer to one) is checked as `acquire` and `init` are.
- The aegis rules decide receivers through std's lists and what is built like them: a type function whose checks return it called again (`Aligned(T, null)`) still makes the container it ends by returning, a constant it declares (a list's `Slice`) is read with the call's arguments, through an `if` or `switch` on them, and a parameter it passes on changed is left unbound. `null` and the booleans are values no aegis type is, a branch that is `null` makes an `if` or `switch` optional, and one that never completes (`return`, `break`, `continue`, `@panic`, `@trap`) is left out. A labeled block is what its `break`s give, and a call through a function pointer field is what the pointer's function type returns. parley's six undecided sites are decided this way, as are about a third of its unresolved candidates.
- A002 finds a copy of an owner that resolves to one by value wherever it comes from (a labeled block that breaks with one), not only one written as a constructor's or an acquisition's result.

### Fixed

- A003 read an acquisition into a released guard (`held = b.acquireUncancelable(io)`) as one only when the operation was named `acquire`; every guard acquisition counts now.
- A003 decides an `if` whatever the owner's state, its branches walked as the block's own: a second release in a branch after a deferred one is found, where it was left undecided.

## [0.2.12] - 2026-10-17

### Added

- A003 reads a guard's `handOff()` (aegis's `Guarded(T).Guard.handOff`, kept in a local or assigned) as a declared transfer: the release passes to the code the hand-off is given, so the acquiring function is decided without following it there, as a release through a callback's erased context stayed undecided (reactor's futex park). A cleanup after the hand-off, a hand-off after cleanup, and a hand-off discarded with `_ =` are found.
- aegis's `Once`, `Lazy` and `Confined` join the contract: their publication state, election lock, waiters and value, and a `Confined`'s value and checked owner, are A001's to keep behind their operations, and a copy of one its constructor made is A002's.

### Fixed

- A001 left a field access undecided whenever its receiver did not resolve and its name was a backing field's of some aegis type: 0.2.11's new names (`state`, `admitted`) left 25 of reactor's sites undecided (`o.state.storage` on a generic operation). A candidate is now decided not aegis's when, for every published type with a backing field of that name, the program reads a member of it the field's declared type lacks, or the receiver is a variable whose literal initializer names a field the type lacks.
- A001 likewise decides `x.name` is not a backing field whose declared type is a struct when the program uses it as a truth value (an `if` or `while` condition, `and`, `or`, `!`), compares it or does arithmetic with it: no struct takes those. `changed` joining the backing names (a `Once`'s condition) would otherwise have left parallax's `span.changed` reads undecided.

## [0.2.11] - 2026-10-17

### Added

- The aegis pack knows every guarded owner: `BlockingGuarded`, `RwGuarded` and `SpinRwGuarded`, their guards (`Guard`, `ReadGuard`, `WriteGuard`) and every way one is acquired, blocking or spinning, cancelable or not, tried, a reader's or a writer's. Their backing state (`data`, `lock`, `mutex`, `state`, `admitted`) and a guard's `owner` are A001's; a guard is A003's to release.
- aegis's `Condition` joins the contract: a guard whose address goes to its `wait` or `waitUncancelable`, which hold it again on every return, is lent, not handed off (A003).
- A003 follows a guard lent to a function of the program's own: when every path of the function hands it back held (each release followed by an acquisition into it, never released at a return, never released by a `defer`, lent on only to calls that do the same), the call is a loan, and the guard stays the caller's to release. An acquisition whose failure is caught (`x.acquire(io) catch return`) is checked as one by `try` is, and a guard read through its members in an `if`'s condition is decided as it is elsewhere. uplink's six undecided sites are decided this way.
- A001 reads an array literal with its element type named (`[_]T{ ... }`) as an array of `T`, so a `for` capture over one is decided.

## [0.2.10] - 2026-10-15

### Added

- The aegis rules decide receivers inside generics. An `anytype` or `type` parameter is the union of what the project's own calls pass, when every use of its function is a call and no consumer can call it by name (its container is not reached through public declarations from a module root). A generic call's result is read with its parameters bound to the call's arguments: a type function returning an expression, a result type written in terms of its parameters, a container it makes (whose fields, now as its methods, read the call's arguments). `@TypeOf` gives a value's type and `@typeInfo` a type's pointer, optional, array and error-union parts and a function's return and parameter types, so `Future(@typeInfo(@TypeOf(f)).@"fn".return_type.?)` and an operation type reflected from a sink's `complete` resolve. A member of a compile-time choice of types leaves out the choices without members (`void`): a build where the access does not compile. Five of reactor's eight undecided A001-A003 sites are decided this way (`Monitor.look`, readiness's `Poller`, `afd.setOption`, a test's `io.concurrent` future, Iocp's operation type with a typed local).

## [0.2.9] - 2026-10-15

### Changed

- Z026, an empty `catch` without a written reason, is a correctness rule (its group `correctness`, where it was `family_policy`): a discarded error is a result nobody read. It stays out of the generic default selection; preflight's default policy gates it. glint gates it in its own lint.

## [0.2.8] - 2026-10-14

### Changed

- A002 decides more copies of plain data: a `@Vector` of plain lanes, the payload `orelse` or `catch` gives of plain data, an `if` expression whose branches are plain, and a labeled block whose every `break` gives plain data. warp's three undecided sites are decided; a labeled block that gives an owner stays undecided, never plain.

## [0.2.7] - 2026-10-14

### Changed

- The aegis rules decide a receiver reached through an array: an element of an array, a pointer to one, a slice or a many-item pointer (`events[1].?.data`), a slice of an array (`segments[0..n].*` is an array of its elements), a `for` over an array value, and `[N]T` as a type. A generic function's result written around its `comptime T: type` parameter (`*T`, `?T`, `[]T`, `[N]T`, `E!*T`) is that result with the call's argument, and a method called on a value counts the value as its first parameter, so `gpa.create(T)` returns `*T`. Literals joined with `++` are plain data, for A002 and as a receiver. On uplink's sources the seven A001 and A002 sites 0.2.6 left undecided are decided.

## [0.2.6] - 2026-10-14

### Changed

- The aegis rules decide a receiver by the type it resolves to, where they left it undecided: the payloads `if`, `while`, `switch` prongs and `for` bind, locals initialised from fields and calls, `!T` results, `catch`, `orelse`, `.?` and grouped expressions, a `switch` or `if` choosing between types (a platform's choice of struct, a `@compileError` branch left out), a function returning its `comptime T: type` parameter, a method of a container a type function made (its parameters read as that call's arguments), a slice's `len` and `ptr`, C's integer types, and numbers from operators no aegis type takes. A resolved type that is not aegis is no candidate; a type nested in a published one, such as a guard, stays undecided. On reactor's sources the undecided sites fall from 81 to 8.
- A002 leaves out a copy of a pointer or an optional pointer, whatever it points at: an alias, which the rule already excluded by declared type.
- A003 follows a release through the branches of an `if` (a release before a `return`, a fallthrough that releases later), a `defer` of the release followed by any statements but another release or a transfer, and a loop's own `break` and `continue`, where it stopped at the first statement after the acquisition.

## [0.2.5] - 2026-10-13

### Changed

- Pins aegis 0.1.6.

## [0.2.4] - 2026-10-13

### Fixed

- A002 decides a copy of plain data instead of leaving it undecided: a copy declared with a primitive type (`usize`, `?bool`, `type`) or an array, slice, pointer, optional or error union of one, or whose source is declared so, is a literal, or is the result of a function declared to return one, copies no owner. Gated, such a copy made the run incomplete, so a package that copies plain data in code that also uses aegis could not gate A002.

## [0.2.3] - 2026-10-12

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.2.2] - 2026-10-12

### Changed

- Pins preflight 0.3.4 and shakedown 0.2.5.

## [0.2.1] - 2026-10-12

### Added

- `glint.version`: the version of glint, as its manifest names it.

### Fixed

- SARIF names the version of glint that wrote it, as its manifest gives it; it named 0.1.0 whatever the version.

## [0.2.0] - 2026-10-11

### Breaking

- glint is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, checks and benchmarks are the development build's (`bay test`, `bay bench`). What a project that depends on glint builds is unchanged: the `glint` module, the `glint` program, `addLinter` and `addLint`.
- One module: the `glint_token` and `glint_cli` build modules are gone. The token facts are `glint.token` (was `glint.Token` and `@import("glint_token")`) and the CLI driver is `glint.cli` (was `@import("glint_cli")`); `addLinter` imports only `glint`. The executable is unchanged.
- Removed `AegisPack.pinned` and `RuleContext.sourceDigest`. The aegis pack recognizes aegis under the module name `aegis`; a caller that mapped aegis's files under other names maps the root as `aegis`.
- Removed 20 unsupported or overlapping policy IDs and `Config.compatibility()` / `--compatibility`. Select reviewed rules explicitly, or all of them with `Config.reviewed()` / `--reviewed`; numeric selections and suppressions reject a removed ID.
- Each rule belongs to one group, correctness, zig_style or family_policy, which its diagnostics name; file, node and token IDs are distinct aegis-backed types. JSON, SARIF and completion formats keep their versions.

### Added

- A project model on std's AST, AstGen and ZIR, with lexical scopes and references, and partial semantic coverage reported as such.
- 21 reviewed rules in three groups. The generic defaults are Z003 and Z013; Z012 and Z026 are family reports with site reasons, and P001–P006 report casts, disabled runtime safety, function length, `unreachable`, debug printing and disallowed calls, each with a written reason where the site needs one. D001 reports dead private declarations and withholds a project it cannot fully resolve.
- The `glint` program: text, JSON and SARIF output, one-site suppressions with a reason, and a versioned completion receipt tied to the invocation, its exit class and its exact output.
- The compiled-rule API with per-source levels and options, `addLinter` for a project's own linter, and `addLint` to run it in a build with its inputs declared.
- `glint.token`: standard-tokenizer facts, one token at a time, with optional policy observation in the same pass; semantic work is requested separately.
- The aegis pack: A001–A005 check operations on aegis types, report-only unless a caller adopts them as gates, with categorized, referenced reasons for site exceptions. `Library(Role)`, `RuleContext.role`, `RuleContext.inLibrary` and `RuleContext.drift` let a pack find a library through the module a program imports it by and the names it publishes, so the pack recognizes aegis at any revision that keeps its public names.
- A frozen Zig projection shared with architecture tools.

### Changed

- Z024 reports past 100 bytes as readability, not a line-length gate, and its split-assertion suggestions keep evaluation effects and stay advisory.
- Pins aegis 0.1.0.

### Fixed

- The aegis scalar gate decides a receiver whose type the program reaches through a module import or another file's alias (`lib.Length`, `cellmod.Index`), through a method of a type a type function returns (`link.index()` declared `?Index`), through the payload of `if (x) |name|` and `while (x) |name|`, and through `orelse`, `catch`, `.?` and `try`. They were undecided, which made a gating run incomplete.
- A published member that does not resolve in a module a file imports is reported as coverage, so a renamed or dropped aegis declaration makes a gate incomplete instead of quiet.
- A type function whose body is one `return` of its container after comptime checks resolves to that container, so `Secret(u32)` and `Bytes(usize)` are recognized through fields and parameters.
- A002 no longer asks about `undefined`, `true`, `false` and `null` initializers, which are values, not owners.
- Lowering of a cut UTF-8 character, of optionals, and of named-test, declaration-literal and reflection references; builtin test contexts are the real ones.
- A rejected AstGen lowering no longer decodes partially initialized ZIR declaration payloads; the analysis stays incomplete.

[Unreleased]: https://github.com/pedronaugusto/glint/commits/main
