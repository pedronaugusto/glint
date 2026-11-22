// A012: aegis's bounded namespace converted to a type by @as, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const ns = @as(type, aegis.bounded);
pub fn f() usize {
    var list: ns.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
