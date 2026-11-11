const std = @import("std");
const P = struct { data: u32 };
pub fn f(a: *const P, b: *const P) bool {
    return std.meta.eql(a.*, b.*);
}
