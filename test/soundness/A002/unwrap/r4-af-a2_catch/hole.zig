// review 4: af/a2_catch.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(e: *anyerror!S(u32), h: *H) void {
    var copy = e.* catch h.s;
    copy.deinit();
}
