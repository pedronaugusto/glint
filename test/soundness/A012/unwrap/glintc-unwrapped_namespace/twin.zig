// A012: aegis's bounded namespace unwrapped from an optional by .?, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const held: ?type = aegis.bounded;
pub fn f() usize {
    var list: held.?.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
