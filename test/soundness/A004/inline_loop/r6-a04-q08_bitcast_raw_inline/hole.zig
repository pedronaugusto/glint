// review 6: a04/q08_bitcast_raw_inline.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q08_bitcast_raw_inline
pub fn f(i: Index) u16 { return @as(u16, @bitCast(i)) + 1; }
