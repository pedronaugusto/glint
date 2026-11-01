// review 4: rt/l_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    var memory: [512]u8 = @splat(0);
    const n: usize = try r.takeInt(u16, .little);
    const s = memory[0..@min(n, memory.len)];
    return s.len - 86;
}
