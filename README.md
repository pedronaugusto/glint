# glint

Work in progress: G2 provides a Zig AST/ZIR source model, configurable built-in and compiled project rules and a standalone CLI. Consumer adoption, broader dead-private admission, later safety rules and predecessor retirement remain open. This is an unreleased development package.

Requires Zig 0.17.0. Runtime dependencies are published aegis and Zig std; preflight and shakedown are dev dependencies through [bay](https://github.com/pedronaugusto/bay), which a project that depends on glint never sees.

## CLI

```sh
git clone https://github.com/pedronaugusto/glint.git
cd glint
zig build -Doptimize=fast
./zig-out/bin/glint src/example.zig
./zig-out/bin/glint --format json --only Z011 --only Z013 src/example.zig
./zig-out/bin/glint --format sarif --reviewed src/example.zig
```

No preflight installation is needed to run the executable. Inputs are explicit files or a newline-separated `--files-from FILE` list. Relative literal imports are followed within the input directories; `--root DIR` adds an allowed import root. `--module NAME=FILE` supplies a named module, `--package NAME=DIR` names the package whose directory holds a file (the innermost one; a P006 entry's `owners` match it), and `--zig-lib-path DIR` supplies the Zig library directory for std resolution. Unconfigured named or computed imports remain unknown. Glint never executes the checked project's build or comptime code.

Default checks are Z003 (parser incompatibility) and Z013 (dead private import binding). `--only ID` (repeated), `--reviewed`, `--family` or `--config FILE` chooses another starting set, one of them; `--report ID`, `--gate ID` and `--disable ID` then set a rule's level, whatever their order. `--reviewed` selects all retained rules for reporting. Diagnostics identify correctness, Zig style and family policy separately; the caller decides which findings gate. Removed IDs and the old compatibility selector are errors. `--max-line-length N` defaults to 100 bytes as a readability report, and `--fact-budget N` and `--strict-suppressions` configure work and suppression limits; see the [design contracts](docs/design.md) for explicit policy. `glint --help` lists every option (the command line is read by [ensign](https://github.com/pedronaugusto/ensign)).

Exit 0 means completed execution with no findings, 1 means completed execution with findings, and 2 means argument, input, traversal, cancellation, output, analysis-budget/frontend or tool failure. Help is not an analysis run. Unresolved facts and unsupported semantic shapes are reported as coverage; completion never certifies compiler type checking or program safety.

## Completion for automation

```sh
./zig-out/bin/glint --result result.json --run-id unique-invocation --format json src/example.zig > diagnostics.json
```

`--result` and `--run-id` come before every other argument, so a command line glint refuses still leaves its record. Use a fresh unpredictable invocation ID and capture the actual exit status and stdout. The version-one sidecar first replaces any old result with `completed: false, outcome: "running"`. It publishes completion by atomic replacement only after all selected analysis and the required stdout write/flush have succeeded. A completed record distinguishes `clean` and `findings` and includes the invocation ID, selected source count, finding/suppression counts, output byte count and SHA-256. Failure records use a distinct outcome and never set `completed: true`; an abrupt interruption can leave the running record. This is an execution/output contract, not a durability guarantee.

Library callers can use `glint.Completion.verify(allocator, result_bytes, invocation_id, exit_code, captured_stdout)`. It rejects stale IDs, malformed/truncated records, wrong versions, interrupted exit codes and truncated/changed output. Only after verification should a caller decide whether particular findings are allowed. A report's `analysis_complete` field alone cannot certify successful output or process completion. Unknown coverage must be considered separately for the intended policy.

## Library

Expose the `glint` module from a commit-pinned package dependency with `dependency.module("glint")`. It is the only module: `glint.token` (standard-tokenizer facts) and `glint.cli` (the driver a project's own linter calls) are namespaces of it, since neither has a dependency or link of its own and Zig analyzes only what a program uses. The consumer build does not load the repository's CI or test dependencies.

```zig
const std = @import("std");
const glint = @import("glint");

fn inspect(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var project = try glint.Project.init(allocator, &.{.{
        .name = "source-label",
        .bytes = "pub const value = 1;",
    }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.run(allocator, &project, .{});
    defer report.deinit();
    try report.write(writer, &project, .json);
}
```

The caller supplies bytes, opaque file identities, diagnostic labels, classification and import edges. The engine opens no paths. Project snapshots own their storage; handles and reports cannot be reused against replacement snapshots. Queries expose declarations, scopes, lexical references and a separately identified partial std-ZIR reference index. Facts preserve unknown reasons rather than resolving generic/comptime behavior by spelling.

## Diagnostics and suppression

Text, JSON version 1 and SARIF 2.1.0 share stable rule IDs, source spans, rule versions, severity/class and coverage. JSON/SARIF include related declaration witnesses for resolved deprecation checks. Text/JSON columns are byte columns; SARIF uses byte regions and URI-encoded labels without mislabeling byte columns as UTF-16 columns. Output ordering is deterministic. Literal dependency scans use `glint.token`, which needs only std; semantic users opt into `Project`. See [the two fact tiers](docs/design.md#two-fact-tiers).

```zig
// glint-ignore: Z013 -- reserved import retained for this documented migration
const future = @import("future");
```

One real comment suppresses one rule at one logical site, either inline or immediately before it. A nonempty written reason is required. Strings and ambiguous multiple sites cannot become silent exemptions; a malformed comment is reported where it is and makes the run incomplete. Stale records are counted; strict mode makes them incomplete.

The aegis pack takes one escape instead, `// aegis: <reason>: <why>`, whose reason is one of `no-danger`, `design`, `hot-loop`, `internal` and `boundary`. It covers the pack's findings on its line, and the report lists each escape with what it covered.

## Limits and ownership

std.zig.Ast and std.zig.AstGen/std.zig.Zir are the front end. Bounded lexical/resource checks precede parsing; selected source limits default to 16 MiB per file and 128 MiB/4096 files per project. This is a partial source engine, with no LLVM, compiler Sema, full generic evaluation, implicit cache, edit reuse or lifetime verifier. Naming rules use known value kinds; computed and unmapped facts remain coverage. Established external ABI function names are preserved. Escape analysis remains pending. Adopted aegis operation checks accept explicit gates with required unknown sites incomplete; no safety proof is claimed.

Gantry owns path dialect and cross-file architecture policy. Preflight orchestrates/configures tools. Glint exposes the shared rule API; consumer writers own adoption. [Design and handoff](docs/design.md) specify exact policy/configuration, compiled-rule helpers, completion and dependency order. Remaining coverage is explicit in the design.

## Development

Run `bay check`, `bay lint`, `bay check-token-portable`, and targeted tests such as `bay test -Dtest-filter=review`. `bay plan -- --workflow .github/workflows/ci.yml` generates the pinned CI caller through preflight. Fast CI validates working candidates; merge CI validates the exact candidate on Linux, macOS and Windows before main advances.

`bay bench` runs only Glint's own ReleaseFast benchmarks. Rows cover parse/lower/cold and warm scans, matched G1r selections, requested allocations, mapped deprecation, private imports, and compiled project rules. CI compiles these; timing is manual. Earlier semantic measurement rows live in private trials. The token drivers and frozen corpus pins are in `bench/`; their measured rows live in private trials. No speed guarantee is claimed.

MIT. See [LICENSE](LICENSE).

The aegis pack checks a program against aegis, the family's safety library. A001-A006 check aegis's types used as their contracts say. The danger rules A007-A020 find where a danger exists and aegis's type is the answer: shared state, secrets, input, integers, units, bounded work, contracts, lifetimes, ownership, identity, state machines, diagnostics to peers, the operations Zig leaves unchecked, and cancellation. Each reads what the code resolves to; a site it cannot decide is undecided, never passed. The pack finds aegis by its published names under the module `aegis` and std under `std` (`--module aegis=path/to/src/root.zig`, `--zig-lib-path DIR`). See [design](docs/design.md#published-aegis-reports-g3) and [the danger rules](docs/design.md#danger-rules).
