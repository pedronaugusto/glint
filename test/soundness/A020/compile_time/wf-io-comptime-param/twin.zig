// warp-fast: the closed-over Io is checked on every pass
const std = @import("std");
var g_io: std.Io = undefined;
fn Spinner(comptime held: *std.Io) type {
    return struct {
        pub fn spin(r: *std.Io.Reader) !u64 {
            const n: u64 = try r.takeInt(u64, .little);
            var t: u64 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                try held.checkCancel();
                t +%= i;
            }
            return t;
        }
    };
}
pub const S = Spinner(&g_io);
