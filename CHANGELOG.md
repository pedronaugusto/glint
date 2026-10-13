# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

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
