//! Completed-run evidence is separate from analysis coverage and process status.
const std = @import("std");
const glint = @import("glint");
const cli = glint.cli;
const aegis_sources = @import("aegis_sources");

/// Where a refused line's message goes in tests that only read the error.
var quiet_buffer: [256]u8 = undefined;
var quiet: std.Io.Writer.Discarding = .init(&quiet_buffer);

fn resultPath(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(path);
    return std.Io.Dir.path.join(a, &.{ path, name });
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
    const status = try cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "test-run", input }, &output.writer, &quiet.writer);
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
    try std.testing.expectError(error.WriteFailed, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "failed-run", input }, &failed, &quiet.writer));
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
    try std.testing.expectError(error.FileNotFound, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "missing", missing }, &output.writer, &quiet.writer));
    try expectOutcome(&tmp, "input_failure");
    try std.testing.expectError(error.InvalidArguments, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "bad-args", "--invalid" }, &output.writer, &quiet.writer));
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
    try std.testing.expectError(error.FileNotFound, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "traversal", input }, &output.writer, &quiet.writer));
    try expectOutcome(&tmp, "traversal_failure");
}

test "a --files-from list names files under the directory glint runs in: an absolute path or a `..` part is refused before anything opens" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    for ([_][]const u8{ "/etc/hosts\n", "src/../../outside.zig\n", "ok.zig\n..\\up.zig\n" }) |listed| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "list.txt", .data = listed });
        const list = try resultPath(a, &tmp, "list.txt");
        defer a.free(list);
        try std.testing.expectError(error.FileListPathOutside, cli.execute(a, std.testing.io, &.{ "glint", "--files-from", list }, &output.writer, &quiet.writer));
    }
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
    _ = try cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "old-success", input }, &output.writer, &quiet.writer);
    const fault = try shakedown.FaultIo.init(a, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .dirRealPathFile, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer fault.deinit();
    try std.testing.expectError(error.Canceled, cli.execute(a, fault.io(), &.{ "glint", "--result", result, "--run-id", "canceled", input }, &output.writer, &quiet.writer));
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
    try std.testing.expectError(error.WriteFailed, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "flush", input }, &failing.writer, &quiet.writer));
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
    try std.testing.expectError(error.SourceTooComplex, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "budget", input }, &output.writer, &quiet.writer));
    try expectOutcome(&tmp, "analysis_incomplete");
}

test "completion help write failure is an output failure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result = try resultPath(a, &tmp, "result.json");
    defer a.free(result);
    var failed: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "help-fails", "--help" }, &failed, &quiet.writer));
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
    try std.testing.expectError(error.UnknownRule, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "removed", "--only", "Z033" }, &output.writer, &quiet.writer));
    try expectOutcome(&tmp, "argument_failure");
    try std.testing.expectError(error.InvalidArguments, cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "retired", "--compatibility" }, &output.writer, &quiet.writer));
    try expectOutcome(&tmp, "argument_failure");
}

test "a rule 0.8 removed is refused with what to write instead, once the packages' rules are read" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = "pub const value = 1;" });
    const input = try resultPath(a, &tmp, "input.zig");
    defer a.free(input);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var problems: std.Io.Writer.Allocating = .init(a);
    defer problems.deinit();
    try std.testing.expectError(error.UnknownRule, cli.execute(a, std.testing.io, &.{ "glint", "--only", "A002", input }, &output.writer, &problems.writer));
    try std.testing.expectEqualStrings("glint: `A002` was removed in glint 0.8: remove it\n", problems.written());
    problems.clearRetainingCapacity();
    try std.testing.expectError(error.UnknownRule, cli.execute(a, std.testing.io, &.{ "glint", "--only", "Z033", input }, &output.writer, &problems.writer));
    try std.testing.expectEqualStrings("glint: `Z033` is not a rule glint has\n", problems.written());
}

test "G2 completion rejects incomplete analysis despite every finding being allowed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.zig", .data = "// glint-ignore: Z012 -- intentionally inference-only factory\npub fn make() Unknown { return .{}; }" });
    const input = try tmp.dir.realPathFileAlloc(std.testing.io, "input.zig", a);
    defer a.free(input);
    const result = try std.Io.Dir.path.join(a, &.{ input[0 .. input.len - 9], "result.json" });
    defer a.free(result);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const status = try cli.execute(a, std.testing.io, &.{ "glint", "--result", result, "--run-id", "incomplete-allowed", "--only", "Z012", "--gate", "Z012", input }, &output.writer, &quiet.writer);
    try std.testing.expectEqual(@as(u8, 2), status); // safe: incomplete analysis uses the failure exit class.
    const receipt = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, result, a, .limited(4096));
    defer a.free(receipt);
    try std.testing.expect(!try glint.Completion.verify(a, receipt, "incomplete-allowed", status, output.written()));
    try std.testing.expect(std.mem.find(u8, receipt, "analysis_incomplete") != null);
}

test "a package directory names its files' package, the innermost one winning" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "extern \"c\" fn fsync(fd: c_int) c_int;\npub fn f() void { _ = fsync(0); }\n";
    try tmp.dir.createDirPath(std.testing.io, "owner/inner");
    try tmp.dir.createDirPath(std.testing.io, "other");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "owner/a.zig", .data = source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "owner/inner/b.zig", .data = source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other/c.zig", .data = source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data =
        \\{"profile": "none", "rules": [{"id": "P006", "level": "gate"}],
        \\ "disallowed": [{"declaration": "fsync", "reason": "durability belongs to airlock", "replacement": "airlock.syncFile", "owners": ["airlock"]}]}
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const paths = [_][]const u8{ "config.json", "owner", "owner/inner", "owner/a.zig", "owner/inner/b.zig", "other/c.zig" };
    var joined: [paths.len][]const u8 = undefined;
    for (paths, &joined) |path, *out| out.* = try std.Io.Dir.path.join(a, &.{ root, path });
    defer for (joined) |path| a.free(path);
    const owner = try std.mem.concat(a, u8, &.{ "airlock=", joined[1] });
    defer a.free(owner);
    const inner = try std.mem.concat(a, u8, &.{ "nested=", joined[2] });
    defer a.free(inner);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const status = try cli.execute(a, std.testing.io, &.{ "glint", "--config", joined[0], "--package", owner, "--package", inner, joined[3], joined[4], joined[5] }, &output.writer, &quiet.writer);
    try std.testing.expectEqual(@as(u8, 1), status); // safe: findings exit.
    try std.testing.expectEqual(null, std.mem.find(u8, output.written(), "a.zig:2"));
    try std.testing.expect(std.mem.find(u8, output.written(), "b.zig:2") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "c.zig:2") != null);
    try std.testing.expectError(error.InvalidPackage, cli.execute(a, std.testing.io, &.{ "glint", "--package", "=dir", joined[3] }, &output.writer, &quiet.writer));
}

test "--only beside --config runs only its rules, under the configuration's options and never its rules" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = "const unused = @import(\"std\");\nextern \"c\" fn fsync(fd: c_int) c_int;\npub fn f() void {\n    _ = fsync(0);\n}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data =
        \\{"profile": "reviewed", "rules": [{"id": "Z013", "level": "gate"}],
        \\ "disallowed": [{"declaration": "fsync", "reason": "durability belongs to airlock", "replacement": "airlock.syncFile", "owners": ["airlock"]}]}
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const file = try std.Io.Dir.path.join(a, &.{ root, "a.zig" });
    defer a.free(file);
    const config = try std.Io.Dir.path.join(a, &.{ root, "config.json" });
    defer a.free(config);
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    const status = try cli.execute(a, std.testing.io, &.{ "glint", "--only", "P006", "--config", config, file }, &output.writer, &quiet.writer);
    try std.testing.expectEqual(@as(u8, 1), status); // safe: findings exit.
    try std.testing.expect(std.mem.find(u8, output.written(), "P006: ") != null);
    try std.testing.expectEqual(null, std.mem.find(u8, output.written(), "Z013"));
    // Without the configuration P006 has no declaration to keep out.
    output.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli.execute(a, std.testing.io, &.{ "glint", "--only", "P006", file }, &output.writer, &quiet.writer));
    try std.testing.expectEqual(null, std.mem.find(u8, output.written(), "P006: "));
}

/// The run's output on `file` under `tmp`, with `options` before it; its status in `status`.
fn runOn(a: std.mem.Allocator, tmp: *std.testing.TmpDir, options: []const []const u8, file: []const u8, status: *u8) ![]u8 {
    return runOnFiles(a, tmp, options, &.{file}, status);
}

/// `runOn` with several files selected, each under `tmp`.
fn runOnFiles(a: std.mem.Allocator, tmp: *std.testing.TmpDir, options: []const []const u8, files: []const []const u8, status: *u8) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    var owned: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned.items) |each| a.free(each);
        owned.deinit(a);
    }
    try args.append(a, "glint");
    for (options) |option| {
        // `NAME=path`: the path under `tmp`.
        if (std.mem.findScalar(u8, option, '=')) |equals| {
            const joined = try std.mem.concat(a, u8, &.{ option[0 .. equals + 1], root, "/", option[equals + 1 ..] });
            try owned.append(a, joined);
            try args.append(a, joined);
        } else try args.append(a, option);
    }
    for (files) |file| {
        const path = try std.Io.Dir.path.join(a, &.{ root, file });
        try owned.append(a, path);
        try args.append(a, path);
    }
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    status.* = try cli.execute(a, std.testing.io, args.items, &output.writer, &quiet.writer);
    return a.dupe(u8, output.written());
}

test "publishing aegis's API turns the pack on and nothing more: a program file republishing it stays the program's, and aegis's own revision under any name is aegis" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const manifest = try a.print(".{{ .name = .aegis, .version = \"0.2.1\", .fingerprint = 0x{x}, .paths = .{{\"\"}} }}\n", .{glint.AegisPack.package.fingerprint});
    defer a.free(manifest);
    for ([_][]const u8{ "aegis", "old" }) |dir| {
        try tmp.dir.createDirPath(std.testing.io, dir);
        var tree = try tmp.dir.openDir(std.testing.io, dir, .{});
        defer tree.close(std.testing.io);
        try aegis_sources.writeTree(a, std.testing.io, tree);
        try tree.writeFile(std.testing.io, .{ .sub_path = "build.zig.zon", .data = manifest });
    }
    const index =
        \\pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
        \\    const i: usize = try r.takeInt(u32, .little);
        \\    return buf[i];
        \\}
        \\pub fn peek(s: *const @import("aegis").Secret(u64)) u64 {
        \\    return s.material;
        \\}
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\nconst common = @import(\"common.zig\");\npub fn g(r: *std.Io.Reader, buf: []const u8) !u8 {\n    const k: common.Secret(u64) = .init(1);\n    _ = k;\n    return common.f(r, buf);\n}\n" });
    // std as 0.17 lays out the read the cases make, and nothing else.
    try tmp.dir.createDirPath(std.testing.io, "lib/std/Io");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/std/std.zig", .data = "pub const Io = @import(\"Io.zig\");\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/std/Io.zig", .data = "pub const Reader = @import(\"Io/Reader.zig\");\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/std/Io/Reader.zig", .data = "pub fn takeInt(r: *@This(), comptime T: type, endian: u1) !T {\n    _ = r;\n    _ = endian;\n    return 0;\n}\n" });
    var status: u8 = undefined;
    // A program file republishing aegis.Secret and SecretBytes, which aegis.secret requires,
    // beside its own code, or forwarding a helper file's: the program's files, read.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "common.zig", .data = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\npub const Secret = aegis.Secret;\npub const SecretBytes = aegis.SecretBytes;\n" ++ index });
    const republished = try runOnFiles(a, &tmp, &.{ "--only", "A001", "--zig-lib-path=lib", "--module", "aegis=aegis/src/root.zig" }, &.{ "main.zig", "common.zig" }, &status);
    defer a.free(republished);
    try std.testing.expect(std.mem.find(u8, republished, "A001: ") != null);
    // aegis's root, imported as aegis, is no namespace module of it: it lacks no member.
    try std.testing.expectEqual(null, std.mem.find(u8, republished, "does not resolve"));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "helpers.zig", .data = "const std = @import(\"std\");\n" ++ index });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "common.zig", .data = "const aegis = @import(\"aegis\");\npub const Secret = aegis.Secret;\npub const SecretBytes = aegis.SecretBytes;\npub const f = @import(\"helpers.zig\").f;\n" });
    const forwarded = try runOnFiles(a, &tmp, &.{ "--only", "A001", "--zig-lib-path=lib", "--module", "aegis=aegis/src/root.zig" }, &.{ "main.zig", "helpers.zig" }, &status);
    defer a.free(forwarded);
    try std.testing.expect(std.mem.find(u8, forwarded, "A001: ") != null);
    // A wrapper package, under its own manifest, republishing aegis's secret types beside its
    // own helper: its files are the program's.
    try tmp.dir.createDirPath(std.testing.io, "wrap");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wrap/build.zig.zon", .data = ".{ .name = .wrap, .version = \"0.1.0\", .fingerprint = 0x2a2a2a2a2a2a2a2a, .paths = .{\"\"} }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wrap/root.zig", .data = "pub const aegis = @import(\"aegis\");\npub const Secret = aegis.Secret;\npub const SecretBytes = aegis.SecretBytes;\npub fn pick(buf: []const u8, i: usize) u8 {\n    return buf[i];\n}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.zig", .data = "const std = @import(\"std\");\nconst w = @import(\"wrap\");\npub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {\n    const k: w.Secret(u64) = .init(1);\n    _ = k.material;\n    const i: usize = try r.takeInt(u32, .little);\n    return w.pick(buf, i);\n}\n" });
    const wrapped = try runOnFiles(a, &tmp, &.{ "--only", "A001", "--zig-lib-path=lib", "--module", "aegis=aegis/src/root.zig", "--module", "wrap=wrap/root.zig", "--package", "wrap=wrap" }, &.{ "app.zig", "wrap/root.zig" }, &status);
    defer a.free(wrapped);
    try std.testing.expect(std.mem.find(u8, wrapped, "A001: ") != null);
    try std.testing.expectEqual(null, std.mem.find(u8, wrapped, "does not resolve"));
    // A second revision of aegis under its own manifest, imported as aegis_old, whose lint_rules
    // names a guard its guarded types do not declare: aegis, its other roles read, the role that
    // does not resolve a gap the run reports where it is imported.
    var old = try tmp.dir.openDir(std.testing.io, "old", .{});
    defer old.close(std.testing.io);
    const root = try old.readFileAlloc(std.testing.io, "src/root.zig", a, .unlimited);
    defer a.free(root);
    const lacking = try std.mem.replaceOwned(u8, a, root, ".member = .Guard }", ".member = .Gaurd }");
    defer a.free(lacking);
    try std.testing.expect(!std.mem.eql(u8, root, lacking));
    try old.writeFile(std.testing.io, .{ .sub_path = "src/root.zig", .data = lacking });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "two.zig", .data = "const old = @import(\"aegis_old\");\nconst Index = old.id.Id(struct {}, u16);\npub fn f(i: Index) u16 {\n    return i.raw() + 1;\n}\n" });
    const second = try runOn(a, &tmp, &.{ "--only", "A004", "--module", "aegis_old=old/src/root.zig" }, "two.zig", &status);
    defer a.free(second);
    try std.testing.expect(std.mem.find(u8, second, "A004: ") != null);
}

test "the aegis pack is on where a file's import of aegis resolves to aegis, and on whatever the files import with --aegis" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cast = "pub fn f(p: *const u32) *const u8 {\n    return @ptrCast(p);\n}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.zig", .data = cast });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "uses.zig", .data = "const aegis = @import(\"aegis\");\ncomptime {\n    _ = aegis;\n}\n" ++ cast });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "renamed.zig", .data = "const safety = @import(\"safety\");\ncomptime {\n    _ = safety;\n}\n" ++ cast });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "by_path.zig", .data = "const aegis = @import(\"aegis/src/root.zig\");\ncomptime {\n    _ = aegis;\n}\n" ++ cast });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.createDirPath(std.testing.io, "aegis");
    var tree = try tmp.dir.openDir(std.testing.io, "aegis", .{});
    defer tree.close(std.testing.io);
    try aegis_sources.writeTree(a, std.testing.io, tree);
    // Aegis's package, by the manifest a dependency's tree holds: its name and fingerprint.
    const manifest = try a.print(".{{ .name = .aegis, .version = \"0.2.1\", .fingerprint = 0x{x}, .paths = .{{\"\"}} }}\n", .{glint.AegisPack.package.fingerprint});
    defer a.free(manifest);
    try tree.writeFile(std.testing.io, .{ .sub_path = "build.zig.zon", .data = manifest });
    var status: u8 = undefined;
    // No aegis: off, and no line.
    const off = try runOn(a, &tmp, &.{}, "plain.zig", &status);
    defer a.free(off);
    try std.testing.expectEqual(@as(u8, 0), status); // safe: a clean exit.
    try std.testing.expectEqual(null, std.mem.find(u8, off, "aegis pack"));
    // --aegis: on, whatever the file imports.
    const forced = try runOn(a, &tmp, &.{"--aegis"}, "plain.zig", &status);
    defer a.free(forced);
    try std.testing.expectEqual(@as(u8, 1), status); // safe: a findings exit.
    try std.testing.expect(std.mem.startsWith(u8, forced, "aegis pack: on\n"));
    try std.testing.expect(std.mem.find(u8, forced, "A019: ") != null);
    // aegis imported: on, with the file that imports it.
    const imported = try runOn(a, &tmp, &.{ "--module", "aegis=aegis/src/root.zig" }, "uses.zig", &status);
    defer a.free(imported);
    try std.testing.expectEqual(@as(u8, 1), status); // safe: a findings exit.
    try std.testing.expect(std.mem.startsWith(u8, imported, "aegis pack: on (imported by "));
    try std.testing.expect(std.mem.find(u8, imported, "A019: ") != null);
    // aegis imported under another module name, or by its path: aegis by what it publishes, on.
    const renamed = try runOn(a, &tmp, &.{ "--module", "safety=aegis/src/root.zig" }, "renamed.zig", &status);
    defer a.free(renamed);
    try std.testing.expectEqual(@as(u8, 1), status); // safe: a findings exit.
    try std.testing.expect(std.mem.startsWith(u8, renamed, "aegis pack: on (imported by "));
    try std.testing.expect(std.mem.find(u8, renamed, "A019: ") != null);
    const by_path = try runOn(a, &tmp, &.{}, "by_path.zig", &status);
    defer a.free(by_path);
    try std.testing.expectEqual(@as(u8, 1), status); // safe: a findings exit.
    try std.testing.expect(std.mem.startsWith(u8, by_path, "aegis pack: on (imported by "));
    // aegis's sources vendored into another package's tree, with no manifest of their own: that
    // package's code, not aegis (aegis is known by its package's identity alone, as a fork keeps
    // its manifest): off, by its name or another, and the cast is the program's own finding.
    try tmp.dir.createDirPath(std.testing.io, "app/libs");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/build.zig.zon", .data = ".{ .name = .app, .version = \"0.1.0\", .fingerprint = 0x1c0ffee5ca1ab1e, .paths = .{\"\"} }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/uses.zig", .data = "const aegis = @import(\"aegis\");\ncomptime {\n    _ = aegis;\n}\n" ++ cast });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app/renamed.zig", .data = "const safety = @import(\"safety\");\ncomptime {\n    _ = safety;\n}\n" ++ cast });
    var vendored = try tmp.dir.openDir(std.testing.io, "app/libs", .{});
    defer vendored.close(std.testing.io);
    try aegis_sources.writeTree(a, std.testing.io, vendored);
    for ([_][2][]const u8{ .{ "aegis=app/libs/src/root.zig", "app/uses.zig" }, .{ "safety=app/libs/src/root.zig", "app/renamed.zig" } }) |case| {
        const in_tree = try runOn(a, &tmp, &.{ "--module", case[0] }, case[1], &status);
        defer a.free(in_tree);
        try std.testing.expectEqual(null, std.mem.find(u8, in_tree, "aegis pack"));
    }
    // A module named aegis that is not aegis: off.
    const other = try runOn(a, &tmp, &.{ "--module", "aegis=fake.zig" }, "uses.zig", &status);
    defer a.free(other);
    try std.testing.expectEqual(@as(u8, 0), status); // safe: a clean exit.
    try std.testing.expectEqual(null, std.mem.find(u8, other, "aegis pack"));
    // --only selects the pack's rules as it selects any: no line.
    const only = try runOn(a, &tmp, &.{ "--only", "A019", "--module", "aegis=aegis/src/root.zig" }, "uses.zig", &status);
    defer a.free(only);
    try std.testing.expectEqual(null, std.mem.find(u8, only, "aegis pack"));
    try std.testing.expect(std.mem.find(u8, only, "A019: ") != null);
}
