// matrix: a std list's items stored in a field through a local, where the next growth moves them
const std = @import("std");
const Cache = struct { view: []u32 = &.{}, list: std.ArrayList(u32) = .empty };
pub fn keep(c: *Cache) void {
    const items = c.list.items;
    c.view = items;
}
