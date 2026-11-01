// matrix: a generic helper, its element type a comptime parameter, checks the size against aegis's Limit before it grows the list
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
fn reserve(comptime T: type, list: *std.ArrayList(T), gpa: std.mem.Allocator, want: usize) !void {
    try limit.check(want);
    try list.ensureTotalCapacity(gpa, want);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, list: *std.ArrayList(u64)) !void {
    try reserve(u64, list, gpa, try r.takeInt(u32, .little));
}
