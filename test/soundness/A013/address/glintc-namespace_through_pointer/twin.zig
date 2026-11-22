// A013: aegis's assert namespace reached through a pointer to it, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const ns = &aegis.assert;
pub fn f(n: u32) u32 {
    ns.*.invariant(n > 0, "a positive count");
    return n - 1;
}
