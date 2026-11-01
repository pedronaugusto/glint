// review 6: a04/q05_bytes_to_value_make.zig
const std = @import("std");
const aegis = @import("aegis");
const Index = aegis.id.Id(struct {}, u16);
// q05_bytes_to_value_make
pub fn f(b: [2]u8) Index { return std.mem.bytesToValue(Index, &b); }
