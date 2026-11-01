// review 6: a04/q01_bitcast_raw.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q01_bitcast_raw
pub fn f(i: Index) u16 { const v: u16 = @bitCast(i); return v + 1; }
