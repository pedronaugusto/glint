// review 6: a04/q02_ptrcast_raw.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q02_ptrcast_raw
pub fn f(i: Index) u16 { const p: *const u16 = @ptrCast(&i); return p.* + 1; }
