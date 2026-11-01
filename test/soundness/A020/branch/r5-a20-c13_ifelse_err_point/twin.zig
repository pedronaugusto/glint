// review 5: a20/c13_ifelse_err_point.zig
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const seed = try r.takeInt(u64, .little);
    var total: u64 = 0;
    while (total != seed) {
        total +%= 1;
        if (io.checkCancel()) |_| {} else |err| return err;
    }
    return total;
}
