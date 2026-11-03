// matrix A008: a switch's `.compare` prong over the program's own union, which calls std's constant-time compare by hand
const std = @import("std");
pub const Check = union(enum) { compare: [32]u8, skip };
pub fn matches(check: Check, tag: [32]u8) bool {
    switch (check) {
        .compare => |expected| return std.crypto.timing_safe.compare(u8, &expected, &tag, .little) == .eq,
        .skip => {},
    }
    return true;
}
