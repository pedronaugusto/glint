// review 4: rt/l_union.zig
const std = @import("std");
const V = union(enum) { bytes: []u8, none };
pub fn f(r: *std.Io.Reader) !usize {
    var memory: [512]u8 = @splat(0);
    const n: usize = try r.takeInt(u16, .little);
    const v: V = .{ .bytes = memory[0..@min(n, memory.len)] };
    switch (v) {
        .bytes => |b| return b.len - 86,
        .none => return 0,
    }
}
