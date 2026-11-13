// A008: the key a plain field of a struct handed to the answer: the struct is the answer's
// argument, its field still holds the key plainly.
const aegis = @import("aegis");
const std = @import("std");
pub const Held = aegis.Secret(struct { key: std.crypto.sign.Ed25519.SecretKey });
