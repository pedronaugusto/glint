// A012: bounded's array, which frees nothing at the scope's end: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn f() usize {
    var list: aegis.bounded.Array(u8, 8) = .init;
    defer _ = &list;
    return list.len();
}
