// matrix: a labeled block gives constants input chooses between; a switch on them meets unreachable on input's path
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    const kind: u8 = blk: {
        if (b == 0) break :blk 1;
        break :blk 2;
    };
    return switch (kind) {
        1 => 10,
        else => unreachable,
    };
}
