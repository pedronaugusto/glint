// review 5: c/c10c_parser_count_base.zig
const std = @import("std");
const aegis = @import("aegis");
const Front = struct { lines: usize };
fn parseLines(_: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Front {
    return .{ .lines = std.mem.count(u8, source, "\n") };
}
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !u8 {
    const table: [16]u8 = @splat(0);
    const front = try aegis.input.Untrusted([]const u8).init(try r.take(4096)).parse(gpa, parseLines);
    return table[front.lines];
}
