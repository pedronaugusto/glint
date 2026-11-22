// A012: aegis's bounded namespace a comptime expression's value, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    const ns = comptime aegis.bounded;
    var list: ns.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
