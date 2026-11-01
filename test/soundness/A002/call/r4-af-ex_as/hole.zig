// review 4: af/ex_as.zig
const S = @import("aegis").Secret;
const R = struct { v: *const u32 };
pub fn f(s: *S(u32)) *const u32 {
    return @as(*const u32, s.expose());
}
