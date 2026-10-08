//! Atomic completed-run sidecar. Consumers verify nonce, exit, length and digest.
const std = @import("std");
const Result = @This();

pub const Outcome = @import("Completion.zig").Outcome;
pub const Request = struct { path: []const u8, run_id: []const u8 };
pub const Record = struct {
    version: u32 = 1,
    run_id: []const u8,
    completed: bool,
    outcome: Outcome,
    sources: usize = 0,
    findings: usize = 0,
    suppressed: usize = 0,
    output_bytes: usize = 0,
    output_sha256: []const u8 = "",
};

pub fn request(args: []const []const u8) !?Request {
    var path: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const is_path = std.mem.eql(u8, args[i], "--result");
        const is_id = std.mem.eql(u8, args[i], "--run-id");
        if (!is_path and !is_id) continue;
        i += 1;
        if (i >= args.len) return error.InvalidResultRequest;
        if (is_path) {
            if (path != null) return error.InvalidResultRequest;
            path = args[i];
        }
        if (is_id) {
            if (id != null) return error.InvalidResultRequest;
            id = args[i];
        }
    }
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
