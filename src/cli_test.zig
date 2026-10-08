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
    try std.testing.expectEqual(@as(u8, if (findings) 1 else 0), status); // safe: explicit compile-time type selection; the value is representable in that type.
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "result.json", a, .limited(65536));
    defer a.free(bytes);
    const json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer json.deinit();
    try std.testing.expect(json.value.object.get("completed").?.bool);
    try std.testing.expectEqualStrings(if (findings) "findings" else "clean", json.value.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("test-run", json.value.object.get("run_id").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(output.written().len)), json.value.object.get("output_bytes").?.integer); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output.written(), &digest, .{});
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

fn expectOutcome(tmp: *std.testing.TmpDir, outcome: []const u8) !void {
    const a = std.testing.allocator;
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "result.json", a, .limited(65536));
    defer a.free(bytes);
    const json = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer json.deinit();
    try std.testing.expect(!json.value.object.get("completed").?.bool);
    try std.testing.expectEqualStrings(outcome, json.value.object.get("outcome").?.string);
}

test "completion missing input and bad arguments never certify clean" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try resultPath(a, &tmp, "missing.zig");
    defer a.free(missing);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try std.testing.expectError(error.FileNotFound, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "missing", missing }, &output.writer));
    try expectOutcome(&tmp, "input_failure");
    try std.testing.expectError(error.UnknownOption, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "bad-args", "--invalid" }, &output.writer));
    try expectOutcome(&tmp, "argument_failure");
}

test "completion unread required import is a traversal failure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = "pub const dep = @import(\"missing.zig\");" });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try std.testing.expectError(error.FileNotFound, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "traversal", input }, &output.writer));
    try expectOutcome(&tmp, "traversal_failure");
}

test "completion canceled input publishes failure and cannot inherit old success" {
    const shakedown = @import("shakedown");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = "pub const value = 1;" });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    _ = try cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "old-success", input }, &output.writer);
    const fault = try shakedown.FaultIo.init(a, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .dirRealPathFile, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer fault.deinit();
    try std.testing.expectError(error.Canceled, cli.execute(a, fault.io(), &.{ "glint", "--result", result, "--run-id", "canceled", input }, &output.writer));
    try expectOutcome(&tmp, "canceled");
}

test "completion flush failure after buffering every byte cannot certify success" {
    const Failing = struct {
        buffer: [4096]u8 = undefined,
        writer: std.Io.Writer,
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = "const d = @import(\"dep\");" });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var failing: Failing = .{ .writer = undefined };
    failing.writer = .{ .vtable = &.{ .drain = Failing.drain }, .buffer = &failing.buffer };
    try std.testing.expectError(error.WriteFailed, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "flush", input }, &failing.writer));
    try std.testing.expect(failing.writer.end > 0);
    try expectOutcome(&tmp, "output_failure");
}

test "completion lexical resource budget refuses a completed run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    try text.writer.writeAll("const x = ");
    try text.writer.splatByteAll('(', 300);
    try text.writer.writeByte('1');
    try text.writer.splatByteAll(')', 300);
    try text.writer.writeByte(';');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = text.written() });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try std.testing.expectError(error.SourceTooComplex, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "budget", input }, &output.writer));
    try expectOutcome(&tmp, "analysis_incomplete");
}

test "completion help write failure is an output failure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var failed: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "help-fails", "--help" }, &failed));
    try expectOutcome(&tmp, "output_failure");
}

test "completion retired rule selections are argument failures" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try std.testing.expectError(error.UnknownRule, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "removed", "--only", "Z033" }, &output.writer));
    try expectOutcome(&tmp, "argument_failure");
    try std.testing.expectError(error.UnknownOption, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "retired", "--compatibility" }, &output.writer));
    try expectOutcome(&tmp, "argument_failure");
}
