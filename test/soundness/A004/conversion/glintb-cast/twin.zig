// glint-b: A004 conversion (cast): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
const E = enum(u16) { a, _ };
pub fn f(v: u16) E {
    return @enumFromInt(v);
}
