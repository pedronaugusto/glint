// matrix: a condition on input stored into a variable, then asserted through a file's alias of std's assert
const std = @import("std");
const assert = std.debug.assert;
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    var ok = false;
    ok = b < 4;
    assert(ok);
    return b;
}
