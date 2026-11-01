// review 4: af/ex_switch.zig
const S = @import("aegis").Secret;
const R = struct { v: *const u32 };
pub fn f(s: *S(u32), k: u8) *const u32 {
    return switch (k) {
        0 => s.expose(),
        else => s.expose(),
    };
}
