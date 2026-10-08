//! Build-only caller: verify complete CLI output before accepting report-level findings.
const std = @import("std");
const glint = @import("glint");

pub fn accepted(a: std.mem.Allocator, receipt: []const u8, nonce: []const u8, status: u8, output: []const u8) !bool {
    if (!try glint.Completion.verify(a, receipt, nonce, status, output)) return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const complete = parsed.value.object.get("analysis_complete") orelse return false;
    if (complete != .bool or !complete.bool) return false;
    const diagnostics = parsed.value.object.get("diagnostics") orelse return false;
    if (diagnostics != .array) return false;
    for (diagnostics.array.items) |diagnostic| {
        if (diagnostic != .object) return false;
        const level = diagnostic.object.get("level") orelse return false;
        if (level != .string or !std.mem.eql(u8, level.string, "report")) return false;
    }
    return true;
}

pub fn main(init: std.process.Init) void {
    const status = execute(init) catch std.process.exit(2);
    if (status != 0) std.process.exit(status);
}
fn execute(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3) return error.MissingLinter;
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const nonce = std.fmt.bytesToHex(&random, .lower);
    const receipt_path = try std.fs.path.join(a, &.{ args[2], &nonce });
    defer std.Io.Dir.cwd().deleteFile(init.io, receipt_path) catch {}; // glint-ignore: Z026 -- scratch receipt removal is best effort after its verified consumption
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, args[1]);
    try argv.appendSlice(a, args[3..]);
    try argv.appendSlice(a, &.{ "--format", "json", "--result", receipt_path, "--run-id", &nonce });
    const result = try std.process.run(a, init.io, .{ .argv = argv.items, .stdout_limit = .limited(128 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    const status = switch (result.term) {
        .exited => |code| code,
        else => return 2,
    };
    const receipt = try std.Io.Dir.cwd().readFileAlloc(init.io, receipt_path, a, .limited(64 * 1024));
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll(result.stdout);
    try output.interface.flush();
    var stderr_buffer: [4096]u8 = undefined;
    var errors = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    try errors.interface.writeAll(result.stderr);
    try errors.interface.flush();
    return if (try accepted(a, receipt, &nonce, status, result.stdout)) 0 else if (status >= 2) 2 else 1;
}
