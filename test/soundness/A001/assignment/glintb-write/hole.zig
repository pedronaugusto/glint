// glint-b: A001 assignment (write): the unsafe shape, which must flag
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
pub fn f(secret: []const u8) Src {
    var p = Src.classify("label", "ok");
    p.bytes = secret;
    return p;
}
