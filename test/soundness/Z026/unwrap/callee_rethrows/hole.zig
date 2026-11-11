// Z026: an empty catch on a call whose callee only rethrows an allocation failure
const std = @import("std");
fn alloc(a: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return a.alloc(u8, 4);
}
fn make(a: std.mem.Allocator) !void {
    const bytes = alloc(a) catch |e| return e;
    a.free(bytes);
}
pub fn run(a: std.mem.Allocator) void {
    make(a) catch {};
}
