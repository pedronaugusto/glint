// A013: aegis's assert namespace an unrolled loop's capture, its invariant called: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(n: u32) u32 {
    inline for (.{aegis.assert}) |ns| ns.invariant(n > 0, "a positive count");
    return n - 1;
}
