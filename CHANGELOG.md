# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Changed (breaking)

- glint's command line is read by ensign 0.2.3 from a declaration (`cli.Arguments`), as `glint-build-gate`'s is: generated help (`--help`), `--version`, completions' spelling, and a mistake named with the nearest option (`unknown option '--onyl'; did you mean '--only'?`). The starting rules are one of `--only` (repeated), `--reviewed`, `--family` and `--config`, and `--report`, `--gate` and `--disable` set levels over them whatever their order; a later value of one option replaces an earlier one. `--enable` goes: it was `--report`. `--result` and `--run-id` come before every other argument, so a line glint refuses still leaves its record (`argument_failure`); `glint-build-gate` passes them so. `cli.execute` and `cli.executeConfigured` take a `problems` writer for a refused line's message, and return `error.InvalidArguments` for one.

### Added

- A003 witnesses: a member of a local owner used where every path has released or transferred it, and an `errdefer` that releases the owner again on an error exit after its cleanup or transfer.
- `Report.stale`: each suppression that suppressed nothing, by the rule it names and its comment's site (`stale_suppressions` stays their number). The text report prints each (`suppression: FILE:LINE:COL: RULE suppresses nothing`, where it printed a count); JSON and SARIF carry the list beside the count. Only suppressions of rules the run checks count: a run that leaves a rule out shows nothing about its suppressions.

### Changed

- A003 reads the owner stored by value where the function does not hold it (`slot.* = fresh`, `h.proxy_secret = kept`, into a container's variable) as a transfer by assignment, as aegis has it: the place's holder releases it. A field of a local value stays undecided. An unlabeled block of its own is walked statement by statement, and branches that leave the owner in different states go on apart while a local flag set to a literal in those branches tells them apart (`if (same) { slot.* = made; swapped = true; } ... if (swapped) return; made.release();`): cloak's ticket-key rotation, relic's credential slots and proxy secret.
- A003 walks an unlabeled `switch`'s prongs as branches (a `catch |err| switch (err)` handler that releases on one prong: relic's secret file read), and reads the owner given by value to a function outside the program's own sources (`try map.put(gpa, key, kept)` of a std map) as moved into the call where nothing names it after; a use after the call stays undecided, as does a call to a function of the program's own.
- A002 decides a generic's copies of its `anytype` parameter where the argument is bound, as it does a type parameter's. A `comptime` parameter's value holds nothing at run time: its copies are no owner's (aegis's `units` digit count, bound by every caller that formats a unit). Arguments plain as written are decided at the binding: a vector (`@Vector(n, T)` reads as an array of its lanes), an enum's or a union's tag named on its type (`Color.red`, `Shape.empty`), `{}`, an anonymous literal of plain values, an element of a typed array of tuples of plain fields, a `for` capture over plain inputs.
- A type built from its fields' types (`@Struct`, `@Union`, `@Tuple`) holds what they do, as a type and as a value of it, as a container and its instance are: its copies are decided by those types (strand's hundred-field and many-arm schemas, its 64-element tuple). The types given as a list resolve through `@as([N]type, ...)`, a `[N]type` variable's initializer and `@splat(T)`; a type function of no parameter is read for the type it makes. A tuple's element named by its number, also over an `inline for`'s capture of a literal, is that element; at an index known only as the program compiles, one of the literal's parts. A binding's choice of types whose pointers, and arrays of them, are aliases copies no owner (strand's checked-copy rejection fixtures).
- A003 reads a local owner's address given to a function of the program's own as its release where that function releases what the parameter points at on every path (`c.owned(true, &owner, fail)` of a function that defers `owner.deinit()`): its body is walked as the caller's is, with the parameter as the owner, a `comptime` `bool` the call passes as a literal settled, and the pointer itself an alias that storing, passing or returning does not move. A path that leaves it held, or anything the walk finds there, leaves the call undecided (aegis's mode-matrix bench).
- A005 follows a whole byte allocation's provenance: `a.dupe(u8, bytes)` and `a.print(format, args)` make one as `a.alloc(u8, n)` does; what a function of the same file returns on every path that gives a value is one where each return is (its allocator read through the call's arguments, `s.gpa` of the receiver `s`), also through an `if` capture and an `orelse` that does not complete; and an adoption of a private function's parameter is decided by every call's argument, the allocator the call passes beside it (relic's `adopted(gpa, bytes)` helper, given a printed header, an allocated one and a prompt's answer).
- An error value among a `switch`'s, an `if`'s, a labeled block's or a loop's branches (`break :deploy error.BareRepository`) makes the others an error union, as `null` makes them optional (relic's up-to-date check in `receive-pack`).
- A tuple written in place with no type of its own (`.{ sha2.Sha256, .sha256 }`) is a literal, as a struct literal is: destructured (`const Hash, const name = pair;`) or iterated by `inline for`, each element is what it holds. A literal holds what its fields or elements do, so a copy of one that holds an owner copies the owner (cloak's RSA-PSS test bound per hash).
- A003 decides what a generic acquires through its type parameter (`T.init(...)` of a `comptime T: type`) at each binding: a type with nothing to release owes nothing; an owner with a release is undecided at the binding, whose cleanup is not walked per binding.
- A003 reads a `MustUse`'s `deinit` after its `take` or `acknowledge` as the check that it was discharged, as aegis has it, no longer a use after release that leaves the site undecided.
- An `inline` prong's capture is each field's payload in turn (`inline else => |m| m.state`), an `else` prong's the fields no other prong names; a capture of differing payloads was undecided (cloak's machine and record protection).
- A `switch` prong on a comptime enum parameter settles it for what the prong reads, as `if` on a comptime `bool` does: a value an earlier `switch` on the same parameter chose is that prong's alone (strand's three readers in `keep_test.zig`); a function that switches on one branches per build for A003.
- A003 reads a `defer` or `errdefer` block that releases the owner once at its top level (`defer { guard.deinit(io); self.gpa.destroy(self); }`), the owner named before the release only through its members and not after it.

### Fixed

- A declaration in a branch's or a loop's block body (`if (c) { var held = g.acquire(); ... }`, the same in `for` and `while`) is the block's: the branch's or loop's scope, spanning the same tokens, took it, and A002, A003 and A005 read only a block's declarations, so an owner declared there was never checked. A guard left held in a loop body was no finding.
- A001-A003 refute an unresolved call on a receiver held at run time (`const owner: T = @ptrCast(raw); owner.read(io, oid)`) by the aegis functions it can call as a method only: a value calls no namespace function (relic's `Database.from` adapter).
- A `while` payload is in scope in the loop's continue expression (`while (at) |layer| : (at = layer.base)`), and in a block body's loop scope: a read of it there resolved to nothing (relic's graph layers).
- Two instantiations of one type function (`Line(Plain)`, `Line(Guarded)`) are two types: a choice of them kept only the first, so a member read through the choice missed the other's finding while the run counted as complete.
- A literal given by a labeled block's `break` takes the block's place: the label was looked for before the block's first token, which is the label itself, so no `break :blk .{ ... }` found its block, and a literal that may be a public source there was undecided (strand's reference backend).
- A made container's declaration that names a type another call makes (`const State = Inner(T); pub const Record = State.Record;`) is read with the bindings of the call that made the container. It was read with the union of every caller's, so `Outer(Plain).Record`'s fields took the types of every `Outer(...)` in the project: undecided sites (chronicle's `record.event`), and a false A001 finding where another caller bound a guard.
- A call given a type is refuted as an aegis operation that takes a value also where the type is made by a function that returns `type` (`access.read(core.Pairs([]const u8, Value))`) or by a builtin that makes types (`@TypeOf`, `@Vector`, `@FieldType`, `@Struct`, ...): `RuleContext.accepts` reads them as types (strand's JSON value reading its object's pairs).
- `@errorReturnTrace()` is `?*std.builtin.StackTrace` and `@src()` a `std.builtin.SourceLocation`, where the project maps std (shakedown's runner resetting the trace's index).
- A function type written in place (`*const fn (?*anyopaque, Io.Dir) void`, a vtable's field) is a type of its own (`Facts.Value.fn_type`), reflected as a declared function is: `@typeInfo(F).@"fn".param_types[i]` and `return_type` give its parameters' and result's types. A copy of a literal reads each part per build, as a choice of types is read A parameter position past a function's list drops that function from a choice of them, as Zig compiles the code only for the others; a switch prong's capture of `@typeInfo(T)` over a choice of types is that part of each (shakedown's simulated `Io` calls, a tuple of a vtable function's parameter, `@typeInfo(R)` of each call's result).
- A generic call's reading keeps its bindings through every expression it reads: an address, a dereference, a slice, `catch` and `orelse`, and every builtin (one reader, the bindings passed), so a result written over an `anytype` parameter (`IndexError!@TypeOf(&slice[0])` of aegis's `Index.get`) is the call's argument's. A made container's generic method whose result the container's bindings leave unknown inside is read with the call's own arguments (airlock's slot lookup, `if (index.get(all)) |s|`). A local's declared type that holds types gives way to its initializer in that reading too.
- `@FieldType(T, name)` of a container a type function made reads the field's type with the bindings of the call that made it, and inside a generic call's reading keeps that call's bindings (`fn state(owner: anytype) *Inner(@FieldType(@typeInfo(@TypeOf(owner)).pointer.child.Record, "event"))`). It read the template's field, and in a call's reading lost the binding of `owner`, so the field's type came from every caller of `Inner` again, this one among them: a cycle, undecided (chronicle's `record.event` copied in `copySince`).

## [0.4.3] - 2026-10-21

### Added

- A002 decides a generic's copies of a value its type parameter types (`var result = value;` of `value: T`) where the parameter is bound: at the definition the copy is the bindings' obligation; a call binding the parameter to a recognized owner is a finding there, naming the copy's line, also through generics that pass the parameter on (as is, or a part of its type information). A binding to a type that does not resolve is undecided; one a surrounding generic's own parameter gives is decided where that is bound. `Facts.parameterCopies`, and the `generic` reason a value is unknown: it depends on a parameter that calls outside the project's reading bind.
- `@FieldType(T, name)` resolves: the field's type, and for a computed name each field's type as a choice.

### Changed

- Z006 accepts a container's declaration whose name a generic reads on its type parameter (`P.identityElement` of a `comptime P: type`) when a type outside the selected sources declares it in public: the generic takes both, so the outside type (std's `Edwards25519`) fixes the spelling.
- Facts read a comptime `bool` parameter's value where the path settles it: inside `if (wrapped)`'s branches, after `if (wrapped) return ...;` (or any branch that never completes), with `!`, `and` and `or`. Zig analyses such a branch only in the instantiations that take it, so a type chosen by the condition (`if (wrapped) *aegis.T else *Direct`, `Owner(wrapped)`, a made container's field) is the one the path takes, and a value carries through type functions' bindings.
- The aegis pack reads a choice of types per build: an operation on it is the owner's in the builds that choose the owner, the other alternatives plain types. A001, A002, A004 and A005 so; A003 when the function does not branch on a comptime condition (its paths are then every build's). A private generic is checked once per binding.
- A type declared inside a published aegis type and not in the contract is plain data to the pack, as an unlisted type at a module's top is (a guarded owner's guard aside): the contract lists every type whose fields are private state, and what such a type holds for its owner is reached through the owner's backing field.
- A container a type function makes through another (`Owned(T, f)` returning `Owner(T, false, f)`) is read with the outer call's bindings; a call through the made type (`Held.initFrom(x)`) and a method's `Self` keep them. A field of a made container whose binding does not resolve takes the template's reading only where every instantiation agrees.

## [0.4.2] - 2026-10-20

### Added

- `RuleContext.accepts`: whether a function's parameters can take a call's arguments by what Zig allows (as many; no literal where a struct is taken; no type where a value of a struct, a pointer or a number is taken). P006 and the aegis pack share it.

### Changed

- The aegis pack decides more receivers. A made container's members are read with the bindings of the call that made it through every expression (`E!?Line(T)`, a type function called inside another, `if`/`switch` arms), one reading for type functions and generic calls; a type the made container declares (`Record`, `Replay`) and a container behind a pointer, optional, error union or array is made by the same call. A001 refutes an unresolved receiver by the other members the file reads of the same expression (`p.name` beside `p.value`). A001-A003 refute an unresolved call `x.name(...)` no library function can be by its arguments (`access.read([]const u8)`: every aegis `read` takes an `Io` or nothing). A002 reads an operator's result and an `if` with one plain branch as plain data (peer types), and an `inline for` over `.{ a, b }` takes each element in turn.
- glint's own lint selects A001-A003 (reported; its own sites are decided by this release, so they gate once the preflight that lints glint carries it).

## [0.4.1] - 2026-10-20

### Added

- E001, reported (a heuristic, designs/glint.md §6): a pointer into a function's own frame carried out of the call: a slice of a local array or a `var`'s address returned, in a returned struct literal, through a `const` alias, or stored through a parameter or into a container's variable. Zig refuses only `return &x` of these.
- `Config.Disallowed.owners`: the packages that own a disallowed declaration. A site in a file of one of them is not governed by the entry, so an owner carries no suppression for its designed use. `Project.Input.package` states a file's package (the name its nearest `build.zig.zon` gives; empty when unknown, which owns nothing); the CLI takes `--package NAME=DIR`, the innermost directory naming a file's package.

## [0.4.0] - 2026-10-18

### Breaking

- `Projection` is gone: nothing consumed it, and the ownership policies it was kept for are P006 over the model every rule reads (docs/design.md, "Ownership policy and adopters").
- `Config.Disallowed.source` is what `@import` takes: a module as programs import it (`std`), or a `.zig` input's name; null names an external symbol. A source without `.zig` that no file imports is nothing to check.
- P006 resolves only the sites that spell a governed name: an alias is found where it is made, not at each use.

### Added

- P006 governs a module's declarations through public namespaces and every alternative of a per-build choice (`c.F.FULLFSYNC`), external functions by their symbol (every `extern fn` of one, std's or the program's, is the function the linker binds; a governed `extern fn` governs its symbol), `@field` with a written name, and `Disallowed.scope = .production` to leave test code out. A governed name whose receiver does not resolve is undecided unless Zig refuses every candidate there: called, by its parameters (count, a literal where a struct is taken, as a method and as a namespace's function); not called, by a declaration the file uses as a receiver of members, which no function or number has. Other unresolved references are not P006's.
- A001 finds `err.PublicSource` built by a struct literal outside aegis, skipping `classify`'s reviewed reason, by the type the literal takes from its place: a declaration's written type, an assignment's target, a call's parameter (a made container's method read with its arguments), its function's result, a field's default, a typed literal's field (through optionals and error unions) or array's element, `@as`, through groupings, branches and labeled breaks. A literal naming exactly its fields whose place does not resolve is undecided.
- A001 reads a runtime machine's `state` (`state.Machine.Runtime`) as its backing field.
- `RuleContext.inTest`.

## [0.3.0] - 2026-10-18

### Breaking

- `RuleContext.usage` is gone with the project-wide reference relation it held: D001 no longer needs it.

### Added

- A006 in the aegis pack: recursion reachable from untrusted input (a parameter of aegis's `input.Untrusted`, or a parser given to its `parse`) without a depth bound, a compared depth the cycle moves (`p + 1` passed on, a field moved by `+=`), reported with the cycle's calls.
- Assertion metrics (`Config.metrics`, `--metrics`): per file and in total, functions, those that assert, and assertion calls by the declaration they resolve to (`std.debug.assert`, aegis's `assert` contracts), unresolved look-alikes apart; a `metrics:` line in text and a `metrics` object in JSON.

### Changed

- D001 decides each file by Zig's own rule that a private declaration is usable only in its file (another file's member access and `@field` are refused, `@hasDecl` and type information see no private declaration, so no std hook calls a private `format`): a private function or variable its file names nowhere, counting every spelling as a use and withholding the file only for a `@field` with a computed name on a receiver that could be a type and does not resolve. The relation it waited on was never complete on real code, so D001 reported nothing; on the family's mains it now finds 169 dead declarations, every one named nowhere else. D001 joins the family profile at report.

## [0.2.15] - 2026-10-17

### Added

- The aegis contract admits five private fields that waited (a staged payload's `payload`, a scope's `index`, a reference's `pointer`, a secondary map's `entries`, unparsed input's `value`) and covers `sync.Atomic` (`cell`; a copy is a second cell), the task contexts `Order(...).Context` and `InitContext` (a copy is a second context), `Order(...).Ordered` (`base`; its ordered acquisitions give guards released by `deinit`), and `id.Counter` as an issuer like `Domain` (a copy issues its ids twice). A runtime machine's `state` still waits (docs/design.md).
- Receivers glint left unknown: `@typeInfo` of a type that does not resolve is still type information, and a switch on it captures the part its prong names; the bytes of `@errorName`, `@tagName`, `@typeName`, `@embedFile` and the numbers of the counting and converting builtins; a slice of a string literal; `const a, const b = x` of a tuple or an array; a loop used as a value (its breaks and `else`); a choice of types per build leaves out `noreturn`, alternatives that lack the member read, and alternatives an unwrap (`.?`, `catch`) does not apply to; a guarded owner's guard recognized by its resolved type, as when passed to an `anytype` parameter.

### Changed

- aegis 0.1.14 (`scope.Ref`'s private `pointer`).

### Fixed

- A container written as a `switch` prong's or an `if` branch's value (`.windows => struct { ... }`) holds its own members: they were read as the branch's, so its fields did not resolve.

## [0.2.14] - 2026-10-17

### Added

- The aegis contract covers every published type past the guards: bounded storage (`Array`, `Ring`/`Queue`, `Buffer`, `RingBuffer`/`QueueBuffer`, `Limit`, `Budget` and its `Reservation`), `own.Owned`, `OwnedIo` and `MustUse`, `Shared`, generational storage (`Pool`, `SlotMap`, `DenseSlotMap`, `SecondaryMap`, `Domain`, `Index`), typestate (`Machine.At`, `Machine.Runtime`), scopes (`Table`, `Table.Scope`, `Ref`), `input.Untrusted` and `secret.Choice`. A001 keeps each one's private state behind its operations, A002 finds a copy of each that is an owner (a reservation released twice, a shared handle copied with `=`, a domain issuing its instances twice, a machine with two drivers), A003 checks that a local one is released by what releases it (`release`, `end`, `deinit`, a `MustUse` taken or acknowledged), or moved into storage the caller names (`moveInto`, `take`), and `Index` is a scalar for A004.
- A003 takes as an acquisition any call that gives an owner by value (`budget.reserve(n)`, `shared.retain()`, `table.open()`), reads an `errdefer` release as covering the error exits after it (a `try`, a `return error.X`), walks a `catch` or `orelse` handler as a branch, and reads an owner carried by value in what is returned (a field of a returned literal, an argument of the call that makes it) as the caller's.
- A002 reads a copy of a guard, a shared handle, a reservation or another owner that moves by assignment as a move when nothing reads the source again (`var guard = free;` out of an `if` capture); a secret's copy, which leaves its bytes unwiped, is still found.
- A005 decides an adoption of a whole byte allocation: a local made by `a.alloc(u8, n)` from the allocator the adoption is given, which nothing uses after the adoption or in a `defer` or `errdefer`.
- The aegis rules decide receivers through more of what programs write: `comptime x`; an untyped struct literal where nothing gives it a type (a block's value), as an anonymous struct; a member of a choice between types that only some alternatives declare, and a receiver that is a pointer to such a choice; arguments passed by `@call`. A generic parameter's callers are found past members of values that only fields can be (Zig has no bound methods): a use other than a call of a member of an address, a `var`, a typed parameter, a dereferenced `anytype` parameter or a field of one, and a member assigned to or used as a number. `++` of two slices is an array of their elements. reactor's backend sites, warp's deflate parser and xenoglyph's grapheme table are decided this way.
- `Project.Input.absent`: the module names the build binds for no module that compiles a file. A call that passes something from one is not compiled in this build and binds nothing: warp's CRC folding, whose x86 kernels are modules only an x86 build has, is decided on ARM.
- A003 follows an owner moved into a local aggregate (a field's value of the struct literal that declares it, the owner named nowhere after) as that local, discharged by giving it to the caller; reads `@field(owner, name)` as a member use; and counts a `return` of a value of an error set (a call that maps one) as an error exit an `errdefer` covers. A call that gives a type aegis declares and the contract does not list (a guard's `Handoff`) owes nothing. clearance's token, registration and fetch sites and reactor's futex park are decided this way.
- `Budget.Reservation.consume()` (aegis 0.1.13) discharges a reservation in A003.
- A library member's path can name a type a type function declares (`Budget.Reservation`), and a type function that returns another's call (`Owned` returning `Owner(...)`) makes that one's container.

### Changed

- aegis 0.1.13, from 0.1.6: glint's own typed ids are unchanged; its tests read the aegis that publishes `Handoff` and `Reservation.consume`.

### Fixed

- The result of a call declared `E!T`, `?T` or `*T`, where `T` is a container, is a value of `T` inside the wrapper, not the type `T`: a copy of a `Shared` handle `create` returned was not seen as an owner.
- A001 left `x.name()` undecided when `x` did not resolve and `name` was a backing field's; a call needs a function, which no backing field of that name holds.

## [0.2.13] - 2026-10-17

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
