const std = @import("std");
const aegis = @import("aegis");
// std.hash.autoHash reads the secret's material by reflection.
pub fn f(s: *const aegis.Secret(u64)) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHash(&h, s.*);
    return h.final();
}
