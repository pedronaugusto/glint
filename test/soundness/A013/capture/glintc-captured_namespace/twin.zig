// A013: aegis's assert namespace captured from an optional, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = aegis.assert;
pub fn f(n: u32) u32 {
    if (held) |ns| ns.invariant(n > 0, "a positive count");
    return n - 1;
}
