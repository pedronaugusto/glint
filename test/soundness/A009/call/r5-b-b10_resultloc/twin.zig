// review 5: b/b10_resultloc.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const a: u32 = try r.takeInt(u32, .little);
    const b: u32 = try r.takeInt(u32, .little);
    const x: u64 = a + b;
    return x;
}
