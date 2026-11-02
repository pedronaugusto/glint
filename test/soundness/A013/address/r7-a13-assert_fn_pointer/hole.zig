// std's assert kept as a function pointer at container level, then called on a peer's byte:
// the pointer's declaration is not at run time and so is no site, and its call is not read.
const std = @import("std");
const check: *const fn (bool) void = &std.debug.assert;
pub fn f(r: *std.Io.Reader) !u8 {
    const line = try r.take(4);
    check(line[0] > 3);
    return line[0];
}
