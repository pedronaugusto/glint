//! Untimed allocation accounting; never changes benchmark timing rows.
const std = @import("std");
const Stats = @This();
backing: std.mem.Allocator,
allocations: usize = 0,
live: usize = 0,
peak: usize = 0,

pub fn allocator(self: *Stats) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}
fn owner(ptr: *anyopaque) *Stats {
    return @ptrCast(@alignCast(ptr)); // safe: allocator() erases a live, aligned Stats pointer, exclusively used by this vtable.
}
fn account(self: *Stats, before: usize, after: usize) void {
    self.live = self.live - before + after;
    self.peak = @max(self.peak, self.live);
}
fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self = owner(ptr);
    const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
    self.allocations += 1;
    self.account(0, len);
    return result;
}
fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
    const self = owner(ptr);
    if (!self.backing.rawResize(memory, alignment, len, ra)) return false;
    self.account(memory.len, len);
    return true;
}
fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
    const self = owner(ptr);
    const result = self.backing.rawRemap(memory, alignment, len, ra) orelse return null;
    self.account(memory.len, len);
    return result;
}
fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const self = owner(ptr);
    self.backing.rawFree(memory, alignment, ra);
    self.account(memory.len, 0);
}
