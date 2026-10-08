//! Completed-run evidence is separate from analysis coverage and process status.
const std = @import("std");
const cli = @import("cli.zig");

fn resultPath(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    return std.fs.path.join(a, &.{ path, name });
}

fn completionCase(findings: bool) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = if (findings) "const unused = @import(\"not-a-file\");" else "pub const value = 1;" });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const status = try cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "test-run", input }, &output.writer);
    try std.testing.expectEqual(@as(u8, if (findings) 1 else 0), status);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "result.json", a, .limited(65536));
    defer a.free(bytes);
    const json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer json.deinit();
    try std.testing.expect(json.value.object.get("completed").?.bool);
    try std.testing.expectEqualStrings(if (findings) "findings" else "clean", json.value.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("test-run", json.value.object.get("run_id").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(output.written().len)), json.value.object.get("output_bytes").?.integer);
    const digest = std.crypto.hash.sha2.Sha256.hash(output.written(), .{});
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(&digest, .lower), json.value.object.get("output_sha256").?.string);
}

test "completion clean analysis has a nonce and complete output digest" {
    try completionCase(false);
}
test "completion findings remain a genuinely completed run" {
    try completionCase(true);
}

test "completion output failure cannot publish success" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = "const unused = @import(\"dep\");" });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var failed: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "failed-run", input }, &failed));
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "result.json", a, .limited(65536));
    defer a.free(bytes);
    const json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer json.deinit();
    try std.testing.expect(!json.value.object.get("completed").?.bool);
    try std.testing.expectEqualStrings("output_failure", json.value.object.get("outcome").?.string);
}
