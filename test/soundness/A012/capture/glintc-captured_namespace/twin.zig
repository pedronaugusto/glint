// A012: aegis's bounded namespace captured from an optional, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = aegis.bounded;
pub fn f() usize {
    if (held) |ns| {
        var list: ns.Array(u8, 8) = .init;
        _ = &list;
        return list.len();
    }
    return 0;
}
