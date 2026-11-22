// A012: aegis's bounded namespace an element of a tuple, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const kinds = .{aegis.bounded};
pub fn f() usize {
    var list: kinds[0].Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
