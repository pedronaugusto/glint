// glint-b: A001 assignment (write): the same shape made safe, which must stay clean
const std = @import("std");
const aegis = @import("aegis");
const G = aegis.Guarded(u32);
const Plain = struct { data: u32 };
const Src = aegis.err.PublicSource;
const Text = struct { bytes: []const u8 };
pub fn f(secret: []const u8) Text {
    var p: Text = .{ .bytes = "ok" };
    p.bytes = secret;
    return p;
}
