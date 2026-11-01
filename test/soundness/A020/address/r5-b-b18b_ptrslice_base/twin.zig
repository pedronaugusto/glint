// review 5: b/b18b_ptrslice_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, p: *[]const u8) !usize {
    const i: usize = try r.takeInt(u32, .little);
    p.* = p.*[0..0];
    return p.len - i;
}
