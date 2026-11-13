// A001: the type's own maker.
const std = @import("std");
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(raw: u32) Id {
    return .fromRaw(raw);
}
