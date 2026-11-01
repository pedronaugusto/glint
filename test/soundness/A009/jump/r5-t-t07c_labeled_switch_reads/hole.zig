// review 5: t/t07c_labeled_switch_reads.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    var i: usize = 0;
    sw: switch (@as(u8, 0)) {
        0 => {
            i += 1;
            continue :sw try r.takeByte();
        },
        else => {},
    }
    return buf[i];
}
