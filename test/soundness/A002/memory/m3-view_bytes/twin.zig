// matrix: plain data's memory copied through a view the program declares
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
fn bytes(p: anytype) *const [@sizeOf(@TypeOf(p.*))]u8 {
    return @ptrCast(p);
}
pub fn f(h: *H, out: *[@sizeOf(u32)]u8) void {
    @memcpy(out, bytes(&h.n));
}
