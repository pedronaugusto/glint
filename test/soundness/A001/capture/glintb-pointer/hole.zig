// glint-b: A001 capture (pointer): the unsafe shape, which must flag
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
pub fn f(gs: []G) void {
    for (gs) |*g| g.data = 1;
}
