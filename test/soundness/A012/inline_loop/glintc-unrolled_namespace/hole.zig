// A012 (opt-in): std's namespace an unrolled loop's capture, its unbounded list made: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    var total: usize = 0;
    inline for (.{std}) |ns| {
        var list: ns.ArrayList(u8) = .empty;
    _ = &list;
        total += list.items.len;
    }
    return total;
}
