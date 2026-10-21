//! Atomic completed-run sidecar. Consumers verify nonce, exit, length and digest.
const std = @import("std");
const Result = @This();
const Completion = @import("Completion.zig");

pub const Outcome = Completion.Outcome;
pub const Request = struct { path: []const u8, run_id: []const u8 };
pub const Record = Completion.Record;

/// The record a caller asked for: a path and a run's name, both or neither.
pub fn request(path: ?[]const u8, id: ?[]const u8) !?Request {
    if (path == null and id == null) return null;
    if (path == null or id == null or path.?.len == 0 or id.?.len == 0 or id.?.len > 128) return error.InvalidResultRequest;
    for (id.?) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidResultRequest;
    return .{ .path = path.?, .run_id = id.? };
}

pub fn publish(a: std.mem.Allocator, io: std.Io, requested: ?Request, record: Record) !void {
    const req = requested orelse return;
    const text = try std.json.Stringify.valueAlloc(a, record, .{});
    const temporary = try a.print("{s}.{s}.pending", .{ req.path, req.run_id });
    const cwd = std.Io.Dir.cwd();
    {
        const file = try cwd.createFile(io, temporary, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, text);
    }
    // The result name is visible only with a complete JSON document. No durability
    // promise: this certifies this process's output, not persistence after a crash.
    try cwd.rename(temporary, cwd, req.path, io);
}
