// A001: std.mem.toBytes reads the governed id a map holds as bytes.
const std = @import("std");
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(names: *const std.StringHashMapUnmanaged(Id), name: []const u8) ?[4]u8 {
    return std.mem.toBytes(names.get(name) orelse return null);
}
