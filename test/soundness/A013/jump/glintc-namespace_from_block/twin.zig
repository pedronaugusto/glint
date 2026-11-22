// A013: aegis's assert namespace a labeled block's result, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const ns = blk: {
    break :blk aegis.assert;
};
pub fn f(n: u32) u32 {
    ns.invariant(n > 0, "a positive count");
    return n - 1;
}
