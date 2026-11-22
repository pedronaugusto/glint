// A013: aegis's assert namespace a container's member, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
const Kit = struct {
    const ns = aegis.assert;
};
pub fn f(n: u32) u32 {
    Kit.ns.invariant(n > 0, "a positive count");
    return n - 1;
}
