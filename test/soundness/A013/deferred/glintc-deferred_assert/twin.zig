// A013: aegis's invariant deferred to the scope's end: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    defer aegis.assert.invariant(n > 0, "a positive count");
    return n - 1;
}
