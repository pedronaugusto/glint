// matrix: a std list's length stored in a field through a local: no borrow of its storage
const std = @import("std");
const Cache = struct { seen: usize = 0, list: std.ArrayList(u32) = .empty };
pub fn keep(c: *Cache) void {
    const n = c.list.items.len;
    c.seen = n;
}
