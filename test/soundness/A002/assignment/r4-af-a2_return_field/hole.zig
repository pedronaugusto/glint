// review 4: af/a2_return_field.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H) S(u32) {
    return h.s;
}
