# glint

Work in progress: G0/G1/G1r provide a std-only Zig source model and 12 reviewed checks and a standalone CLI. Family integration, new safety-rule admission and retirement of the predecessor have not landed. This is an unreleased development package.

Requires Zig 0.17.0. Runtime dependencies are Zig std only; preflight and shakedown are lazy build/test dependencies.

## CLI

```sh
git clone https://github.com/pedronaugusto/glint.git
cd glint
zig build -Doptimize=fast
./zig-out/bin/glint src/example.zig
./zig-out/bin/glint --format json --only Z011 --only Z013 src/example.zig
./zig-out/bin/glint --format sarif --reviewed src/example.zig
```

No preflight installation is needed to run the executable. Inputs are explicit files or a newline-separated `--files-from FILE` list. Relative literal imports are followed within the input directories; `--root DIR` adds an allowed import root. `--module NAME=FILE` supplies a named module, and `--zig-lib-path DIR` supplies the Zig library directory for std resolution. Unconfigured named or computed imports remain unknown. Glint never executes the checked project's build or comptime code.

Default checks are Z003 (parser incompatibility) and Z013 (dead private import binding). `--only ID` starts an explicit selection; `--enable ID` and `--disable ID` amend it. `--reviewed` selects all retained rules for reporting. Diagnostics identify correctness, Zig style and family policy separately; the caller decides which findings gate. Removed IDs and the old compatibility selector are errors. `--max-line-length N` defaults to 100 bytes as a readability report, and `--fact-budget N` and `--strict-suppressions` configure work and suppression limits. See the [reviewed contracts](docs/rules.md).

Exit 0 means completed execution with no findings, 1 means completed execution with findings, and 2 means argument, input, traversal, cancellation, output, analysis-budget/frontend or tool failure. Help is not an analysis run. Unresolved facts and unsupported semantic shapes are reported as coverage; completion never certifies compiler type checking or program safety.

## Completion for automation

```sh
./zig-out/bin/glint --format json --result result.json --run-id unique-invocation src/example.zig > diagnostics.json
```

Use a fresh unpredictable invocation ID and capture the actual exit status and stdout. The version-one sidecar first replaces any old result with `completed: false, outcome: "running"`. It publishes completion by atomic replacement only after all selected analysis and the required stdout write/flush have succeeded. A completed record distinguishes `clean` and `findings` and includes the invocation ID, selected source count, finding/suppression counts, output byte count and SHA-256. Failure records use a distinct outcome and never set `completed: true`; an abrupt interruption can leave the running record. This is an execution/output contract, not a durability guarantee.

Library callers can use `glint.Completion.verify(allocator, result_bytes, invocation_id, exit_code, captured_stdout)`. It rejects stale IDs, malformed/truncated records, wrong versions, interrupted exit codes and truncated/changed output. Only after verification should a caller decide whether particular findings are allowed. A report's `analysis_complete` field alone cannot certify successful output or process completion. Unknown coverage must be considered separately for the intended policy.

## Library

Expose the `glint` module from a commit-pinned package dependency with `dependency.module("glint")`. The consumer build does not load the repository's CI or test dependencies.

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

Text, JSON version 1 and SARIF 2.1.0 share stable rule IDs, source spans, rule versions, severity/class and coverage. JSON/SARIF include related declaration witnesses for resolved deprecation checks. Text/JSON columns are byte columns; SARIF uses byte regions and URI-encoded labels without mislabeling byte columns as UTF-16 columns. Output ordering is deterministic.

```zig
// glint-ignore: Z013 -- reserved import retained for this documented migration
const future = @import("future");
```

One real comment suppresses one rule at one logical site, either inline or immediately before it. A nonempty written reason is required. Strings, malformed directives and ambiguous multiple sites cannot become silent exemptions. Stale records are counted; strict mode makes them incomplete. Legacy suppression spelling is not silently migrated; that remains a later retirement seam.

## Limits and ownership

std.zig.Ast and std.zig.AstGen/std.zig.Zir are the front end. Bounded lexical/resource checks precede parsing; selected source limits default to 16 MiB per file and 128 MiB/4096 files per project. This is a partial source engine, with no LLVM, compiler Sema, full generic evaluation, implicit cache, edit reuse or lifetime verifier. Naming rules use known value kinds; computed and unmapped facts remain coverage. Established external ABI function names are preserved. Escape analysis and the aegis rule pack await later admission; no safety proof is claimed.

Gantry owns path dialect and cross-file architecture policy. Preflight orchestrates/configures tools. Glint owns source analysis; G2 integration and G3 adoption are not implemented here. The [dated results note](docs/results.md) cites private G1/G1r evidence. G1r records rule contracts and removals in the review; G2 integration and G3 safety adoption are still work in progress.

## Development

Run `zig build check`, `zig build lint`, and targeted tests such as `zig build test -Dtest-filter=review`. `zig build plan -- --workflow .github/workflows/ci.yml` generates the pinned CI caller through preflight. Fast CI validates working candidates; merge CI validates the exact candidate on Linux, macOS and Windows before main advances.

`zig build bench` runs only Glint's own ReleaseFast benchmarks. Rows cover parse, std lowering, cold project/core analysis, warm core and reviewed-rule runs, requested allocations, mapped deprecation and private-import checks. `--smoke` checks small fixtures without timing. [Retained measurements](https://github.com/pedronaugusto/trials/blob/f501b66f9679760f5fadd118b95bfb36670a891b/glint/g1/paired-core.json) and the [import-index correction](https://github.com/pedronaugusto/trials/blob/f501b66f9679760f5fadd118b95bfb36670a891b/glint/g1/paired-import-index.json) expose costs and scope; G0's unavailable compatibility rules are never a valid speed baseline. Private comparative drivers and dated records live in [trials](https://github.com/pedronaugusto/trials/tree/f501b66f9679760f5fadd118b95bfb36670a891b/glint).

MIT. See [LICENSE](LICENSE).
