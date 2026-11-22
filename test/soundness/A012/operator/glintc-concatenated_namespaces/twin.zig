// A012: aegis's bounded namespace an element of tuples joined by ++, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{aegis.bounded};
pub fn f() usize {
    var list: both[1].Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
