// A001: a map's get copies out the governed id it was given: storage the map keeps is no
// reflection (shakedown's simulated host names).
const std = @import("std");
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(names: *const std.StringHashMapUnmanaged(Id), name: []const u8) ?Id {
    return names.get(name);
}
