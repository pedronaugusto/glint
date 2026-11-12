// P007: a member of std.c named by @field (review 8, m2).
const std = @import("std");
pub fn f() c_int {
    return @field(std.c, "getpid")();
}
