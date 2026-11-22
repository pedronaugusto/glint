// A008: aegis's wipe deferred to the scope's end, through an alias: none.
const aegis = @import("aegis");
const std = @import("std");
const secret = aegis.secret;
pub fn use(seed: [32]u8) u8 {
    var key = seed;
    defer secret.wipe(&key);
    return key[0];
}
