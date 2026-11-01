// review 4: rt/i_check64.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const raw = try r.takeInt(u64, .little);
    if (raw > std.math.maxInt(u32)) return error.Big;
    const n: usize = @intCast(raw);
    return n + n;
}
