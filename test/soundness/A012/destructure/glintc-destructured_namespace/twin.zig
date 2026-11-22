// A012: aegis's bounded namespace named by a destructure, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    const ns, _ = .{ aegis.bounded, @as(u8, 0) };
    var list: ns.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
