// review 4: af/base.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H) void {
    const copy = h.s;
    _ = copy;
}
