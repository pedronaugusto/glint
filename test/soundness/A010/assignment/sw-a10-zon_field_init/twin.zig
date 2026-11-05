// A010 (glint-c, ZON review): the same field, 2 from small.zon and 1: at most 9 + 2, which fits a u8.
const std = @import("std");
const K = struct { n: u8 };
const loaded: K = @import("small.zon");
const fallback: K = .{ .n = 1 };
fn add(k: K, r: *std.Io.Reader) !u8 {
    const raw = try r.takeByte();
    return (raw % 10) + k.n;
}
pub fn use(r: *std.Io.Reader, which: bool) !u8 {
    return add(if (which) loaded else fallback, r);
}
