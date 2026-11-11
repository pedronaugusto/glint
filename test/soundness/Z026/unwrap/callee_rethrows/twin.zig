// Z026 twin: the catch counts the error
const std = @import("std");
fn alloc(a: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return a.alloc(u8, 4);
}
fn make(a: std.mem.Allocator) !void {
    const bytes = alloc(a) catch |e| return e;
    a.free(bytes);
}
var failures: u32 = 0;
pub fn run(a: std.mem.Allocator) void {
    make(a) catch {
        failures += 1;
    };
}
