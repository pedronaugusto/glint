// A012: aegis's bounded namespace a labeled block's result, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const ns = blk: {
    break :blk aegis.bounded;
};
pub fn f() usize {
    var list: ns.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
