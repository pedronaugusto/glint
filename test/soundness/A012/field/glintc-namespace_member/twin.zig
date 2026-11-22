// A012: aegis's bounded namespace a container's member, its bounded array made: none.
const aegis = @import("aegis");
const std = @import("std");
const Kit = struct {
    const ns = aegis.bounded;
};
pub fn f() usize {
    var list: Kit.ns.Array(u8, 8) = .init;
    _ = &list;
    return list.len();
}
