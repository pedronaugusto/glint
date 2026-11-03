// matrix A008: the same `.compare` prong, a tag of the program's own union that names no std declaration
const std = @import("std");
pub const Check = union(enum) { compare: [32]u8, skip };
pub fn matches(check: Check, tag: [32]u8) bool {
    switch (check) {
        .compare => |expected| return std.mem.eql(u8, &expected, &tag),
        .skip => {},
    }
    return true;
}
