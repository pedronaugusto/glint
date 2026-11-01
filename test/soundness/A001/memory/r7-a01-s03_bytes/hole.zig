// review 7 pre: a01/s03_bytes.zig
const std = @import("std");
const aegis = @import("aegis");
// The secret's material read out of its bytes.
pub fn f(s: *const aegis.Secret(u64)) u64 {
    return std.mem.bytesToValue(u64, std.mem.asBytes(s)[0..8]);
}
