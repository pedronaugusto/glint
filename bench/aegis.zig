//! The cost of the rules aegis declares, on the pinned aegis sources, read as a real run reads
//! them: glint's command line, aegis by its module and std from the build's Zig, a store shared
//! by the rounds as a run per case shares one; fixtures are not admission evidence.
const std = @import("std");
const glint = @import("glint");
const sources = @import("aegis_sources");
const bench = @import("preflight_bench_options");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    // The smoke proves the row completes and counts exactly its sites, in one round; a
    // measured run keeps its rounds.
    const smoke = args.len > 1 and std.mem.eql(u8, args[1], "--smoke");
    const rounds: usize = if (args.len > 2 and std.mem.eql(u8, args[1], "--rounds")) try std.fmt.parseInt(usize, args[2], 10) else if (smoke) 1 else 100;
    const core = args.len > 3 and std.mem.eql(u8, args[3], "core");
    const n: usize = if (smoke) 4 else 128;
    var source: std.Io.Writer.Allocating = .init(a);
    try source.writer.writeAll("const S = @import(\"aegis\").Secret;\n");
    for (0..n) |i| try source.writer.print("pub fn site{d}(s: *S(u32)) void {{ _ = s.aegis_material; }}\n", .{i});
    const consumer = "aegis_consumer.zig";
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = consumer, .data = source.written() });
    // The rules aegis declares, each on by its own default, glint's own off: A001 finds each
    // internal field read. `core`: no rule at all.
    const policy = "aegis_policy.json";
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = policy, .data = if (core) "{\"profile\": \"none\"}" else "{\"rules\": [{\"id\": \"Z003\", \"level\": \"off\"}, {\"id\": \"Z013\", \"level\": \"off\"}]}" });
    // aegis's pinned tree under its own manifest, imported as `aegis`, as a build hands it.
    try std.Io.Dir.cwd().createDirPath(init.io, "aegis");
    var tree = try std.Io.Dir.cwd().openDir(init.io, "aegis", .{});
    defer tree.close(init.io);
    try sources.writeTree(a, init.io, tree);
    try tree.writeFile(init.io, .{ .sub_path = "build.zig.zon", .data = try a.print(".{{ .name = .{s}, .version = \"0.0.0\", .fingerprint = 0x{x}, .paths = .{{\"\"}} }}\n", .{ sources.package.name, sources.package.fingerprint }) });
    const argv = [_][]const u8{ "glint", "--zig-lib-path", try zigLib(a, init.io), "--module", "aegis=aegis/src/root.zig", "--config", policy, consumer };
    var store: glint.Project.Store = .init(init.gpa);
    defer store.deinit();
    const start = std.Io.Clock.awake.now(init.io);
    var findings: usize = 0;
    for (0..rounds) |_| {
        var output: std.Io.Writer.Allocating = .init(init.gpa);
        defer output.deinit();
        var problems: std.Io.Writer.Allocating = .init(init.gpa);
        defer problems.deinit();
        const status = try glint.cli.execute(init.gpa, init.io, &argv, &output.writer, &problems.writer, .{ .store = &store });
        findings = 0;
        var lines = std.mem.splitScalar(u8, output.written(), '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "error: ") or std.mem.startsWith(u8, line, "suppression: ")) continue;
            if (std.mem.find(u8, line, consumer ++ ":") != null) findings += 1;
        }
        if (status == 2 or findings != (if (core) @as(usize, 0) else n)) {
            var told: [4096]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &told);
            try stderr.interface.print("glint-aegis: status {d}, {d} findings where {d}:\n{s}{s}", .{ status, findings, if (core) @as(usize, 0) else n, output.written(), problems.written() });
            try stderr.interface.flush();
            return error.UnexpectedPackResult;
        }
    }
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("row=warm_aegis total_ns={d} rounds={d} observed={d} bytes={d}\n", .{ start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds(), rounds, findings, source.written().len });
    try stdout.interface.flush();
}

/// The library of the Zig the build uses, where a real run reads std: found as Zig finds its
/// own, `lib` or `lib/zig` holding `std/std.zig` beside the compiler or above it.
fn zigLib(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    var dir = std.Io.Dir.path.dirname(bench.zig);
    while (dir) |at| : (dir = std.Io.Dir.path.dirname(at)) {
        for ([_][]const u8{ "lib", "lib/zig" }) |below| {
            const lib = try std.Io.Dir.path.join(a, &.{ at, below });
            const holds = if (std.Io.Dir.cwd().access(io, try std.Io.Dir.path.join(a, &.{ lib, "std", "std.zig" }), .{})) |_| true else |err| switch (err) {
                error.FileNotFound => false,
                else => |e| return e,
            };
            if (holds) return lib;
        }
    }
    return error.ZigLibNotFound;
}
