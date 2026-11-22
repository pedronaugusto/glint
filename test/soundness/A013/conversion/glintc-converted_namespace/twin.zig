// A013: aegis's assert namespace converted to a type by @as, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const ns = @as(type, aegis.assert);
pub fn f(n: u32) u32 {
    ns.invariant(n > 0, "a positive count");
    return n - 1;
}
