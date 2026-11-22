// Z026: a handler that breaks its own label with a value made from the error: nothing discarded.
const std = @import("std");
fn f() !void {}
fn count(err: anyerror) u8 {
    return @intFromBool(err == error.OutOfMemory);
}
pub fn g() u8 {
    f() catch |err| return blk: {
        break :blk count(err);
    };
    return 0;
}
