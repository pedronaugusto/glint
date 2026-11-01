// review 6: a04/q07_inttoenum_make.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q07_inttoenum_make
pub fn f(v: u16) !Index { return std.enums.fromInt(Index, v) orelse error.Bad; }
