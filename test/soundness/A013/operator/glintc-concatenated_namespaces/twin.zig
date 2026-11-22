// A013: aegis's assert namespace an element of tuples joined by ++, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{aegis.assert};
pub fn f(n: u32) u32 {
    both[1].invariant(n > 0, "a positive count");
    return n - 1;
}
