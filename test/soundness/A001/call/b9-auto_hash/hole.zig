// A001: a Secret hashed by std's autoHash, which reads every field by reflection.
const aegis = @import("aegis");
const std = @import("std");
pub fn hash(s: aegis.Secret([32]u8)) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHash(&h, s);
    return h.final();
}
