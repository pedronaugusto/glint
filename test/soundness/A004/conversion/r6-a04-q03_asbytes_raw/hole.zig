// review 6: a04/q03_asbytes_raw.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q03_asbytes_raw
pub fn f(i: Index) u16 { return std.mem.readInt(u16, std.mem.asBytes(&i), .little) + 1; }
