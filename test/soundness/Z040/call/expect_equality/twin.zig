// Z040 twin: the same done the way the rule leaves
const std = @import("std");
test {
    const a: u32 = 1;
    try std.testing.expectEqual(1, a);
}
