// A012: aegis's bounded namespace chosen by an if, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const wide = false;
const ns = if (wide) aegis.bounded else aegis.bounded;
pub fn f() usize {
    var list: ns.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
