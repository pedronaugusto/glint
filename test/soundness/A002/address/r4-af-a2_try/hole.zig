// review 4: af/a2_try.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(e: *anyerror!S(u32)) !void {
    var copy = try e.*;
    copy.deinit();
}
