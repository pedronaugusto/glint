// review 5: p/p04_thread_spawn.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
fn worker(n: u32, out: *u8) void {
    out.* = table[n];
}
pub fn f(r: *std.Io.Reader) !void {
    var out: u8 = 0;
    const n = try r.takeInt(u32, .little);
    const t = try std.Thread.spawn(.{}, worker, .{ n, &out });
    t.join();
}
