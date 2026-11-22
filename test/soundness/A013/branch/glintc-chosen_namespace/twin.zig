// A013: aegis's assert namespace chosen by an if, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const ns = if (wide) aegis.assert else aegis.assert;
pub fn f(n: u32) u32 {
    ns.invariant(n > 0, "a positive count");
    return n - 1;
}
