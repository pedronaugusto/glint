//! Build-only caller: verify complete CLI output before accepting report-level findings.
const std = @import("std");
const glint = @import("glint");
const ensign = @import("ensign");
const aegis = @import("aegis");

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

/// The build's call: the linter, a directory for its run's record, and the linter's arguments.
const Gate = struct {
    linter: []const u8,
    scratch: []const u8,
    arguments: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .name = "glint-build-gate",
        .about = "Run a glint linter; accept its report only from a complete run, verified by its record, whose findings are all at report level",
        .options = .{
            .linter = .{ .positional = true, .value_name = "LINTER", .hint = .command, .help = "The linter to run" },
            .scratch = .{ .positional = true, .value_name = "DIR", .hint = .directory, .help = "Where the run's record is written, then read" },
            .arguments = .{ .positional = true, .raw = true, .value_name = "ARGUMENT", .help = "The linter's arguments, as given" },
        },
    };
};

pub fn main(init: std.process.Init) void {
    const gate = ensign.parseOrExit(Gate, init);
    const status = execute(init, gate) catch std.process.exit(2);
    if (status != 0) std.process.exit(status);
}
fn execute(init: std.process.Init, gate: Gate) !u8 {
    const a = init.arena.allocator();
    var random: [16]u8 = undefined;
    init.io.random(&random);
    const nonce = std.fmt.bytesToHex(&random, .lower);
    const receipt_path = try std.Io.Dir.path.join(a, &.{ gate.scratch, &nonce });
    defer std.Io.Dir.cwd().deleteFile(init.io, receipt_path) catch {}; // glint-ignore: Z026 -- scratch receipt removal is best effort after its verified consumption
    // The record is asked for first, so a line the linter refuses still leaves one; the
    // report is JSON whatever the arguments ask, as the check reads it.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ gate.linter, "--result", receipt_path, "--run-id", &nonce });
    try argv.appendSlice(a, gate.arguments);
    try argv.appendSlice(a, &.{ "--format", "json" });
    const result = try std.process.run(a, init.io, .{ .argv = argv.items, .stdout_limit = .limited(128 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    const status = switch (result.term) {
        .exited => |code| code,
        else => return 2,
    };
    const receipt = try aegis.own.readFile(init.io, std.Io.Dir.cwd(), receipt_path, a, .fromRaw(64 * 1024));
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
