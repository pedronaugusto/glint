// P006 assignment: a type function's var, with no `comptime` of its own, holding a pointer type
// and given std.Io, its member read after: the disallowed std.Io.async is reached
pub fn F() type {
    var X = []const u8;
    X = @import("std").Io;
    const Y = X;
    return struct {
        pub const run = Y.async;
    };
}
