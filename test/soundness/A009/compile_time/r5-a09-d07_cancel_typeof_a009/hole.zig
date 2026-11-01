// review 5: a09/d07_cancel_typeof_a009.zig
const std = @import("std");
pub fn f(io: std.Io, r: *std.Io.Reader, out: *u64) !void {
    const n = try r.takeInt(u64, .little);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        _ = @TypeOf(try io.checkCancel());
        out.* +%= i;
    }
}
