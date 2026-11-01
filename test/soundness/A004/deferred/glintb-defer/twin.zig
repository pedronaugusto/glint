// glint-b: A004 deferred (defer): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16, out: *u16) void {
    defer out.* = i +| 1;
}
