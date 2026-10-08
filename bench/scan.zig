//! Own benchmark: parsing, std lowering, cold project/binding and shared rules.
const std = @import("std");
const glint = @import("glint");
const Stats = @import("allocations.zig");
const smoke = @import("builtin").mode == .debug;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const small = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const count: usize = if (small) 4 else 256;
    const rounds: usize = if (small) 1 else 15;
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..count) |n| try text.writer.print("pub const Item{d} = struct {{ value: u32, pub fn read(self: Item{d}) u32 {{ return self.value; }} }};\n", .{ n, n });
    const source = try a.dupeSentinel(u8, text.written(), 0);
    const inputs: []const glint.Project.Input = &.{.{ .name = "benchmark", .stem = "Benchmark", .bytes = source }};
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.print("version=1 bytes={d} files=1 declarations={d} rounds={d} optimize={s}\n", .{ source.len, count, rounds, @tagName(@import("builtin").mode) });
    const start = now(init.io, small);
    var nodes: usize = 0;
    for (0..rounds) |_| {
        var tree = try std.zig.Ast.parse(init.gpa, source, .{});
        nodes = tree.nodes.len;
        tree.deinit(init.gpa);
    }
    try row(writer, "parse", elapsed(init.io, start, small), rounds, nodes);
    var tree = try std.zig.Ast.parse(init.gpa, source, .{});
    defer tree.deinit(init.gpa);
    const lower_start = now(init.io, small);
    var instructions: usize = 0;
    for (0..rounds) |_| {
        var zir = try std.zig.AstGen.generate(init.gpa, tree);
        instructions = zir.instructions.len;
        zir.deinit(init.gpa);
    }
    try row(writer, "lower", elapsed(init.io, lower_start, small), rounds, instructions);
    const cold_start = now(init.io, small);
    for (0..rounds) |_| {
        var project = try glint.Project.init(init.gpa, inputs, &.{}, .{});
        defer project.deinit();
        var report = try glint.run(init.gpa, &project, .{});
        defer report.deinit();
        if (!report.complete or report.diagnostics.len != 0) return error.UnexpectedCoreResult;
    }
    try row(writer, "cold_core", elapsed(init.io, cold_start, small), rounds, instructions);
    var project = try glint.Project.init(init.gpa, inputs, &.{}, .{});
    defer project.deinit();
    inline for (.{ false, true }) |all| {
        const rules_start = now(init.io, small);
        var findings: usize = 0;
        for (0..rounds) |_| {
            var report = try glint.run(init.gpa, &project, if (all) glint.Config.reviewed() else .{});
            defer report.deinit();
            findings = report.diagnostics.len;
            if (!all and (!report.complete or findings != 0)) return error.UnexpectedCoreResult;
        }
        try row(writer, if (all) "warm_reviewed" else "warm_core", elapsed(init.io, rules_start, small), rounds, findings);
    }
    var stats: Stats = .{ .backing = init.gpa };
    {
        var measured = try glint.Project.init(stats.allocator(), inputs, &.{}, .{});
        defer measured.deinit();
        var report = try glint.run(stats.allocator(), &measured, .{});
        defer report.deinit();
    }
    if (stats.live != 0) return error.LeakedBenchmarkOwner;
    try writer.print("row=cold_core_memory allocations={d} peak_requested_bytes={d} live_after={d}\n", .{ stats.allocations, stats.peak, stats.live });
    try semanticRows(init.gpa, init.io, writer, rounds, small);
    try writer.flush();
}

fn now(io: std.Io, small: bool) std.Io.Timestamp {
    if (small or smoke) return .{ .nanoseconds = 0 };
    return std.Io.Clock.awake.now(io);
}
fn elapsed(io: std.Io, start: std.Io.Timestamp, small: bool) i96 {
    return start.durationTo(now(io, small)).toNanoseconds();
}
fn row(writer: *std.Io.Writer, label: []const u8, ns: i96, rounds: usize, observed: usize) !void {
    try writer.print("row={s} total_ns={d} rounds={d} observed={d}\n", .{ label, ns, rounds, observed });
}

fn semanticRows(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, rounds: usize, small: bool) !void {
    const root = "const dep = @import(\"dep\"); const Alias = dep.S; pub fn f(v: Alias) Alias { _ = dep.old(); return v; }";
    const dependency = "/// Deprecated: use the replacement.\npub fn old() u8 { return 1; } pub const S = struct { value: u8 };";
    const inputs: []const glint.Project.Input = &.{ .{ .name = "root", .stem = "Root", .bytes = root }, .{ .name = "dependency", .stem = "Dependency", .bytes = dependency, .selected = false } };
    const imports: []const glint.Project.Import = &.{.{ .from = @fromBackingInt(0), .spelling = "dep", .target = @fromBackingInt(1) }}; // safe: the two frozen fixture sources have indexes zero and one.
    var config = glint.Config.none();
    for ([_]glint.Rule{.Z011}) |rule| config.set(rule, true);
    try writer.print("case=cross_module bytes={d} files=2 rounds={d}\n", .{ root.len + dependency.len, rounds });
    const cold = now(io, small);
    for (0..rounds) |_| {
        var project = try glint.Project.init(gpa, inputs, imports, .{});
        defer project.deinit();
        var report = try glint.run(gpa, &project, config);
        defer report.deinit();
        if (!report.complete or report.diagnostics.len != 1 or report.diagnostics[0].rule != .Z011) return error.UnexpectedCrossModuleResult;
    }
    try row(writer, "cold_cross_module", elapsed(io, cold, small), rounds, 1);
    var project = try glint.Project.init(gpa, inputs, imports, .{});
    defer project.deinit();
    const warm = now(io, small);
    for (0..rounds) |_| {
        var report = try glint.run(gpa, &project, config);
        defer report.deinit();
        if (!report.complete or report.diagnostics.len != 1) return error.UnexpectedCrossModuleResult;
    }
    try row(writer, "warm_cross_module", elapsed(io, warm, small), rounds, 1);
    const source = "const unused = @import(\"unused\");";
    var import_project = try glint.Project.init(gpa, &.{.{ .name = "private_import", .bytes = source }}, &.{}, .{});
    defer import_project.deinit();
    try writer.print("case=private_import bytes={d} files=1 rounds={d}\n", .{ source.len, rounds });
    const import_start = now(io, small);
    for (0..rounds) |_| {
        var report = try glint.run(gpa, &import_project, .{});
        defer report.deinit();
        if (!report.complete or report.diagnostics.len != 1 or report.diagnostics[0].rule != .Z013) return error.UnexpectedImportResult;
    }
    try row(writer, "warm_private_import", elapsed(io, import_start, small), rounds, 1);
}
