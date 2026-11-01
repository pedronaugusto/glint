// review 4: af/ex_ptrcast.zig
const S = @import("aegis").Secret;
const R = struct { v: *const u32 };
pub fn f(s: *S(u32)) *const [4]u8 {
    return @ptrCast(s.expose());
}
