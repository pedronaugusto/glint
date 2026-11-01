// review 4: af/a2_orelse.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(o: *?S(u32), h: *H) void {
    var copy = o.* orelse h.s;
    copy.deinit();
}
