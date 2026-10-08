# Changelog

## Unreleased

- Add opt-in, report-only published aegis operation checks A001–A005 through the compiled-rule API.
- Require categorized, referenced site reasons for pack exceptions; reject pack gate selections.
- Pin published aegis A4 and green published tooling.


All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

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
