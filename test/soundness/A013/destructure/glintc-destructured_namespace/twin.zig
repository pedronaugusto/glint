// A013: aegis's assert namespace named by a destructure, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    const ns, _ = .{ aegis.assert, @as(u8, 0) };
    ns.invariant(n > 0, "a positive count");
    return n - 1;
}
