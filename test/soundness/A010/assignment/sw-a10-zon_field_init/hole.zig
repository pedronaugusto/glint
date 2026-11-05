// A010 (glint-c, ZON review): a field a ZON file initializes is written there: K.n takes 250 from big.zon as well as 1, so the sum overflows a u8.
const std = @import("std");
const K = struct { n: u8 };
const loaded: K = @import("big.zon");
const fallback: K = .{ .n = 1 };
fn add(k: K, r: *std.Io.Reader) !u8 {
    const raw = try r.takeByte();
    return (raw % 10) + k.n;
}
pub fn use(r: *std.Io.Reader, which: bool) !u8 {
    return add(if (which) loaded else fallback, r);
}
