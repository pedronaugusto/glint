// glint-b: A001 capture (value): the same shape made safe, which must stay clean
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
pub fn f(maybe: ?*Plain) u32 {
    if (maybe) |g| return g.data;
    return 0;
}
