// review 5: a09/d09_flag_literals.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, out: *u64) !void {
    const n = try r.takeInt(u64, .little);
    var i: u64 = 0;
    var more = true;
    while (more) : (i += 1) {
        out.* +%= i;
        if (i == n) more = false;
    }
}
