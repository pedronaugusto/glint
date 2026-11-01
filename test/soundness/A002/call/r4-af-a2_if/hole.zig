// review 4: af/a2_if.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H, c: bool) void {
    var copy = if (c) h.s else h.t;
    copy.deinit();
}
