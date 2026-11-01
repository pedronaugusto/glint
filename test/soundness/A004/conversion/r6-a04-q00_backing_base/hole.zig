// review 6: a04/q00_backing_base.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q00_backing_base
pub fn f(i: Index) u16 { return @backingInt(i) + 1; }
