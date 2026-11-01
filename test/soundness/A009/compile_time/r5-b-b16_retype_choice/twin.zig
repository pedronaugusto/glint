// review 5: b/b16_retype_choice.zig
const std = @import("std");
fn get(comptime wide: bool, r: *std.Io.Reader) !(if (wide) u64 else u8) {
    if (wide) return try r.takeInt(u64, .little);
    return try r.takeInt(u8, .little);
}
pub fn f(r: *std.Io.Reader) !u64 {
    const v = try get(true, r);
    return v * 1000;
}
