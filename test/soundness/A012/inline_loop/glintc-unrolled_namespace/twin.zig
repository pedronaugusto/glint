// A012: aegis's bounded namespace an unrolled loop's capture, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    var total: usize = 0;
    inline for (.{aegis.bounded}) |ns| {
        var list: ns.Array(u8, 8) = .init;
    _ = &list;
        total += list.len();
    }
    return total;
}
