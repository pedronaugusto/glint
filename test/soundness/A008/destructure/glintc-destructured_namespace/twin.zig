// A008: aegis's secret named by a destructure, its comparison called through it: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn same(a: [32]u8, b: [32]u8) aegis.secret.Choice {
    const secret, const mem = .{ aegis.secret, std.mem };
    _ = mem;
    return secret.equal(32, &a, &b);
}
