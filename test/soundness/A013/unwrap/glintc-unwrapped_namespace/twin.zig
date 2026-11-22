// A013: aegis's assert namespace unwrapped from an optional by .?, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = aegis.assert;
pub fn f(n: u32) u32 {
    held.?.invariant(n > 0, "a positive count");
    return n - 1;
}
