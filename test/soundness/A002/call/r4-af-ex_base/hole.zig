// review 4: af/ex_base.zig
const S = @import("aegis").Secret;
const R = struct { v: *const u32 };
pub fn f(s: *S(u32)) *const u32 {
    return s.expose();
}
