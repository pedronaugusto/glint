// review 4: af/a2_literal.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H, out: *H) void {
    out.* = .{ .s = h.s, .t = h.t };
}
