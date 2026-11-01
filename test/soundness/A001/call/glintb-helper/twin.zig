// glint-b: A001 call (helper): the same shape made safe, which must stay clean
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
fn look(p: anytype) u32 {
    return p.data;
}
pub fn f(g: *Plain) u32 {
    return look(g);
}
