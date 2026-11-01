// review 4: af/a2_blk.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H) void {
    var copy = blk: {
        break :blk h.s;
    };
    copy.deinit();
}
