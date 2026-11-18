//! glint's output on a file it shares with others: each run writes at the file's offset and
//! moves it, so `glint >> log` keeps what the log held and `{ echo A; glint; echo B; } > f`
//! keeps that order. The tests run from the package root, where `programs.glint` names glint.
const std = @import("std");
const builtin = @import("builtin");
const programs = @import("programs");
const aegis = @import("aegis");

/// A run that prints: a one-line coverage report over a file in the package.
// A finding, so the run writes something: a clean run writes nothing.
const arguments = [_][]const u8{ programs.glint, "--only", "Z045", "examples/report.zig" };

test "glint >> f keeps what f held and appends each run" {
    switch (builtin.os.tag) {
        // Windows has no O_APPEND: a shell's `>>` opens the file at its end and hands that
        // handle to each command, which the file written through its own handle matches.
        .windows => {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const output = try alone(a, io);
            const file = try tmp.dir.createFile(io, "f", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "old\nold\n");
            try runOn(io, file);
            try runOn(io, file);
            try expectFile(a, io, tmp.dir, &.{ "old\nold\n", output, output });
        },
        else => {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const output = try alone(a, io);
            try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "old\nold\n" });
            const fd = try std.posix.openat(tmp.dir.handle, "f", .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
            const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
            defer file.close(io);
            try runOn(io, file);
            try runOn(io, file);
            try expectFile(a, io, tmp.dir, &.{ "old\nold\n", output, output });
        },
    }
}

test "{ echo A; glint; echo B; } > f keeps that order" {
    // A shell's `> f` gives every command one file object and so one offset; glint writes
    // through a streaming writer, which moves the offset it shares (PositionalStream holds it
    // to that). On Windows the run is made as a shell makes it, `f`'s handle inherited (see
    // `runOn`).
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try alone(a, io);
    const file = try tmp.dir.createFile(io, "f", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "A\n");
    try runOn(io, file);
    try file.writeStreamingAll(io, "B\n");
    try expectFile(a, io, tmp.dir, &.{ "A\n", output, "B\n" });
}

/// What the run writes on a pipe, which has no offset.
fn alone(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try std.process.run(a, io, .{ .argv = &arguments });
    try std.testing.expect(result.stdout.len != 0);
    return result.stdout;
}

/// Runs glint with `file` as its stdout, its stderr dropped.
fn runOn(io: std.Io, file: std.Io.File) !void {
    if (builtin.os.tag == .windows) return runInheriting(file);
    var child = try std.process.spawn(io, .{ .argv = &arguments, .stdin = .ignore, .stdout = .{ .file = file }, .stderr = .ignore });
    _ = try child.wait(io);
}

/// Runs glint as a Windows shell does for `> f`: the child's stdout is `file`'s own handle,
/// inherited, so parent and child share one file object and its offset. std's spawn opens
/// the file again for the child (Io/Threaded.zig, `.file` reopened by `OpenFile` from its
/// handle), another file object with its offset at 0, which writes over what the file held
/// (release run 44177284014).
fn runInheriting(file: std.Io.File) !void {
    const windows = std.os.windows;
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    // The arguments hold no quote and none ends in a backslash, so each one quoted is read back
    // as itself.
    var line: std.ArrayList(u8) = .empty;
    for (arguments, 0..) |argument, i| {
        std.debug.assert(std.mem.findScalar(u8, argument, '"') == null);
        std.debug.assert(!std.mem.endsWith(u8, argument, "\\"));
        if (i != 0) try line.append(fixed.allocator(), ' ');
        try line.print(fixed.allocator(), "\"{s}\"", .{argument});
    }
    const command = try std.unicode.wtf8ToWtf16LeAllocZ(fixed.allocator(), line.items);
    // On an error the test closes the handle, which ends what it would give a later child.
    try setInherit(file.handle, true);
    var startup: windows.STARTUPINFOW = .{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .dwFlags = windows.STARTF_USESTDHANDLES,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = null,
        .hStdOutput = file.handle,
        .hStdError = null,
    };
    var process: windows.PROCESS.INFORMATION = undefined;
    if (!windows.kernel32.CreateProcessW(null, command.ptr, null, null, .TRUE, .{}, null, null, &startup, &process).toBool())
        return windows.unexpectedError(windows.GetLastError());
    defer windows.CloseHandle(process.hProcess);
    defer windows.CloseHandle(process.hThread);
    switch (windows.ntdll.NtWaitForSingleObject(process.hProcess, .FALSE, null)) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    try setInherit(file.handle, false);
}

fn setInherit(handle: std.os.windows.HANDLE, inherit: bool) !void {
    const windows = std.os.windows;
    switch (windows.ntdll.NtSetInformationObject(handle, .HandleFlag, &windows.OBJECT.HANDLE_FLAG{ .INHERIT = inherit }, @sizeOf(windows.OBJECT.HANDLE_FLAG))) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
}

fn expectFile(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, parts: []const []const u8) !void {
    const actual = try aegis.own.readFile(io, dir, "f", a, .fromRaw(1024 * 1024));
    try std.testing.expectEqualStrings(try std.mem.concat(a, u8, parts), actual);
}
