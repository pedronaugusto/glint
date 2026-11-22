// A013: aegis's assert namespace a comptime expression's value, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    const ns = comptime aegis.assert;
    ns.invariant(n > 0, "a positive count");
    return n - 1;
}
