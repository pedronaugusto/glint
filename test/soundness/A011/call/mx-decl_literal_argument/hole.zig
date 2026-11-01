// matrix: a raw count handed to std's sleep as a decl literal argument, its type given by the parameter
const std = @import("std");
pub fn f(io: std.Io, ms: i64) !void {
    try io.sleep(.fromMilliseconds(ms), .awake);
}
