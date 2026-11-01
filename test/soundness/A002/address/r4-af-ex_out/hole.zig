// review 4: af/ex_out.zig
const S = @import("aegis").Secret;
const R = struct { v: *const u32 };
pub fn f(s: *S(u32), out: **const u32) void {
    out.* = s.expose();
}
