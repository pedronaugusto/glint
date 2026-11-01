// review 6: a04/q04_bitcast_make.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q04_bitcast_make
pub fn f(v: u16) Index { return @bitCast(v); }
