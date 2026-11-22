// A008: aegis's secret the result of a labeled block, its comparison called: none.
const aegis = @import("aegis");
const std = @import("std");
pub fn same(a: [32]u8, b: [32]u8) aegis.secret.Choice {
    const secret = blk: {
        break :blk aegis.secret;
    };
    return secret.equal(32, &a, &b);
}
