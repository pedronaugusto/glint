//! Optional pack cost on the pinned aegis sources; fixtures are not admission evidence.
const std = @import("std");
const glint = @import("glint");
const sources = @import("aegis_sources");
const pack = glint.AegisPack;
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rounds: usize = if (args.len > 2 and std.mem.eql(u8, args[1], "--rounds")) try std.fmt.parseInt(usize, args[2], 10) else 100;
    const core = args.len > 3 and std.mem.eql(u8, args[3], "core");
    const n: usize = if (args.len > 1 and std.mem.eql(u8, args[1], "--smoke")) 4 else 128;
    var source: std.Io.Writer.Allocating = .init(init.arena.allocator());
    try source.writer.writeAll("const S = @import(\"aegis\").Secret;\n");
    for (0..n) |i| try source.writer.print("pub fn site{d}(s: *S(u32)) void {{ _ = s.material; }}\n", .{i});
    var project = try sources.project(init.gpa, source.written());
    defer project.deinit();
    const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{
        .{ .rule = pack.access, .level = .report },   .{ .rule = pack.copies, .level = .report },
        .{ .rule = pack.cleanup, .level = .report },  .{ .rule = pack.scalar, .level = .report },
        .{ .rule = pack.capacity, .level = .report },
    } };
    const start = std.Io.Clock.awake.now(init.io);
    var findings: usize = 0;
    for (0..rounds) |_| {
        var report = try glint.runConfigured(init.gpa, &project, if (core) glint.Config.none() else config, .{ .project_rules = &pack.rules });
        defer report.deinit();
        if (!report.complete or report.diagnostics.len != (if (core) @as(usize, 0) else n)) return error.UnexpectedPackResult;
        findings = report.diagnostics.len;
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.print("row=warm_aegis total_ns={d} rounds={d} observed={d} bytes={d}\n", .{ start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds(), rounds, findings, source.written().len });
    try output.interface.flush();
}
