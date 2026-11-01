// glint-b: A001 compile_time (known): the unsafe shape, which must flag
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
pub fn f(g: *G) u32 {
    const name = "da" ++ "ta";
    return @field(g, name);
}
