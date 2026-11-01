// matrix A008: the same comparison by aegis, which answers a Choice.
const std = @import("std");
const aegis = @import("aegis");
const Ed25519 = std.crypto.sign.Ed25519;
pub fn same(a: *const Ed25519.SecretKey, b: *const Ed25519.SecretKey) bool {
    return aegis.secret.equal(64, &a.bytes, &b.bytes).declassify("the caller acts on the match");
}
