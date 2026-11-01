// glint-b: A004 deferred (defer): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index, out: *u16) void {
    defer out.* = i.raw() + 1;
}
