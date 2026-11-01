// review 6: a04/q06_ptrcast_make.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q06_ptrcast_make
pub fn f(v: *const u16) Index { const p: *const Index = @ptrCast(v); return p.*; }
