// A wipe by hand through the program's own byte view of the key (a function returning its parameter's memory).
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
fn view(p: *Ed25519.SecretKey) *[Ed25519.SecretKey.encoded_length]u8 {
    return &p.bytes;
}
pub fn forget(kp: *Ed25519.KeyPair) void {
    @memset(view(&kp.secret_key), 0);
}
