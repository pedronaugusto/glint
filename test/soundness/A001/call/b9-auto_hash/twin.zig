// A001: the material a Secret exposes through its own API, hashed by std's autoHash.
const aegis = @import("aegis");
const std = @import("std");
pub fn hash(s: *const aegis.Secret([32]u8)) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHash(&h, s.expose().*);
    return h.final();
}
