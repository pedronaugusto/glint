// A013: aegis's assert namespace an element of a tuple, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const kinds = .{aegis.assert};
pub fn f(n: u32) u32 {
    kinds[0].invariant(n > 0, "a positive count");
    return n - 1;
}
