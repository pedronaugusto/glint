// Z042: the reported form
const std = @import("std");
test {
    const a: u32 = 1;
    try std.testing.expectEqual(a, 1);
}
