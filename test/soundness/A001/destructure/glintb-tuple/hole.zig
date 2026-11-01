// glint-b: A001 destructure (tuple): the unsafe shape, which must flag
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
pub fn f(secret: []const u8) Src {
    var p = Src.classify("label", "ok");
    var n: usize = 0;
    p.bytes, n = .{ secret, 1 };
    _ = &n;
    return p;
}
