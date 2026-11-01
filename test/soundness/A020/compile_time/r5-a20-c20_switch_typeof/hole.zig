// review 5: a20/c20_switch_typeof.zig
const std = @import("std");
pub fn spin(io: std.Io) !void {
    var n: u64 = 0;
    state: switch (@as(u8, 0)) {
        0 => {
            _ = @TypeOf(try io.checkCancel());
            n +%= 1;
            continue :state 0;
        },
        else => {},
    }
}
