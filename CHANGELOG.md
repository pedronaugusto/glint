# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Fixed (aegis types the program names, 2026-10-10)

- The aegis scalar gate decides a receiver whose type the program reaches through a module import or another file's alias (`lib.Length`, `cellmod.Index`), through a method of a type a type function returns (`link.index()` declared `?Index`), through the payload of `if (x) |name|` and `while (x) |name|`, and through `orelse`, `catch`, `.?` and `try`. They were undecided, which made a gating run incomplete.

### Changed (one module, 2026-10-10)

- Breaking: the `glint_token` and `glint_cli` build modules are gone. Neither had a dependency or link of its own, so they were namespaces held apart: the token facts are `glint.token` (was `glint.Token` and `@import("glint_token")`) and the CLI driver is `glint.cli` (was `@import("glint_cli")`). `addLinter` now imports only `glint`. The `glint` module is the only module; the executable is unchanged.
- The CLI driver and its completion sidecar import the files they use directly and sit below the public root in the layer order, which `ci/layers.zig` enforces.
- Updated the green shakedown pin.

### Changed (aegis by published names, 2026-10-10)

- Added `Library(Role)`, `RuleContext.role`, `RuleContext.inLibrary` and `RuleContext.drift`: a pack finds a library's declarations through the module a program imports it by and the public paths it publishes. The aegis pack uses them, so A001–A005 recognize aegis at any revision that keeps its public names (checked on four: the first published, f199c0d, b77c659 and 586602b). Before, the pack recognized the sources of one aegis commit by digest and every other revision came back "no resolved operation contract" with the gates quiet.
- A published member that does not resolve in a module a file imports is reported as coverage, so renaming or dropping an aegis declaration makes a gate incomplete instead of quiet.
- Breaking: removed `AegisPack.pinned` and `RuleContext.sourceDigest`. The pack recognizes aegis only under the module name `aegis` (and `aegis.<namespace>`); a caller that mapped aegis's files under other names maps the root as `aegis`. Rule versions are unchanged.
- A type function whose body is one `return` of its container after comptime checks now resolves to that container, so instances such as `Secret(u32)` and `Bytes(usize)` are recognized through fields and parameters; a body with several returns still has none. No reviewed-rule diagnostic changed on the family.
- A002 no longer asks about `undefined`, `true`, `false` and `null` initializers, which are values and not owners; they were most of its unresolved coverage.
- Updated green aegis, preflight and shakedown pins.

### Changed (token tier, 2026-10-09)

- Added independent `glint_token` standard-tokenizer facts, with optional policy observation made in the same pass, one token at a time; semantic AST/ZIR work is requested separately.
- Fixed cut UTF-8 character lowering, optional lowering, named-test/declaration-literal/reflection references and actual builtin test contexts.
- A001–A005 version 2 accept explicit gate adoption while preserving undecided required sites. Generic defaults are unchanged.
- Updated green aegis, preflight and shakedown pins; embedded public-module tests no longer require a hidden shakedown import.
- Documented fact ordering, source/arena lifetime, coverage and the externally owned Preflight adoption contract.

### Added (G3, 2026-10-09)

- Opt-in report-only published aegis operation checks A001–A005 through the compiled-rule API.
- Categorized, referenced site reasons for pack exceptions; pack gate selections are rejected.
- Published aegis A4 and green published tooling pins, with an own pack benchmark.

### Added

- Immutable project model using std AST, AstGen and ZIR, lexical scopes/references and explicit partial semantic coverage.
- Twelve reviewed rule identities, separated into correctness, Zig style and family policy. Naming uses resolved kinds and reports unknown facts.
- Standalone text/JSON/SARIF CLI, reasoned one-site suppression and a versioned completion receipt tied to invocation, exit class and exact successful output.
- Public consumer, ownership/allocation, semantic, rule and interrupted/error-output contracts; own benchmarks and counted family differential evidence.

### Development status

- G2 API implementation; consumer adoption remains open. Family integration, new safety adoption and predecessor retirement remain pending; no lifetime verifier is pursued and this is not a release-complete claim.

### Changed (G1r, 2026-10-08)

- Breaking: removed 20 unsupported or overlapping policy IDs and `Config.compatibility()` / `--compatibility`; select reviewed rules explicitly or use `Config.reviewed()` / `--reviewed`. Numeric selections and suppressions reject removed IDs.
- Breaking: diagnostic rule version 2 names correctness, zig_style and family_policy groups; JSON version 1 and the independent completion contract remain unchanged.
- Z024 defaults to a 100-byte readability report; it is not a universal line-length gate. Split assertion suggestions preserve evaluation effects and stay advisory.
- Tests, benchmarks and the consumer fixture remain here; evidence stays outside the package. Published green preflight/shakedown pins refreshed, and CI uses the canonical planner.

[Unreleased]: https://github.com/pedronaugusto/glint/commits/main

### Changed (G2, 2026-10-08)

- Breaking: distinct aegis-backed file/node/token IDs and rule metadata version 3; explicit reviewed selection expands to 21 IDs. Generic defaults stay Z003/Z013; JSON/SARIF and completion versions remain unchanged.
- Restore Z012/Z026 as explicit family reports with site reasons. Add configured cast/safety-off/length/unreachable/debug-print/disallowed predicates and a conservative dead-private report which withholds unresolved projects.
- Public compiled-rule API, per-source levels/options, native input build helper and complete-output verification before accepting reports; shared frozen Zig projection for architecture consumers.
- Rejected AstGen lowering no longer decodes partially initialized ZIR declaration payloads; failed analysis remains incomplete.
- Pin published green aegis for typed identities and checked byte accounting. Planned Untrusted/bounded leaves and broad dead-private family admission remain open; consumer repos are unchanged.
- Lasting contracts moved to docs/design.md; removed historical results/review tables under the owner package-content rule.
