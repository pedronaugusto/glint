// A001: std.meta.tags reads a governed enum's tags by reflection (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f() usize {
    return std.meta.tags(Id).len;
}
