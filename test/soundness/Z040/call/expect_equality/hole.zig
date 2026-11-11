// Z040: the reported form
const std = @import("std");
test {
    const a: u32 = 1;
    try std.testing.expect(a == 1);
}
