// review 4: af/a2_typed_literal.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H) H {
    const copy = H{ .s = h.s, .t = h.t };
    return copy;
}
