// review 5: b/b18c_ptrslice_callee.zig
const std = @import("std");
fn drop(p: *[]const u8) void {
    p.* = p.*[0..0];
}
pub fn f(r: *std.Io.Reader, p: *[]const u8) !usize {
    const i: usize = try r.takeInt(u32, .little);
    if (i > p.len) return 0;
    drop(p);
    return p.len - i;
}
