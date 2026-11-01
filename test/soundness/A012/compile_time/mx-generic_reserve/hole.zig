// matrix: a size from input handed to a generic helper, its element type a comptime parameter, which grows a std list by it
const std = @import("std");
fn reserve(comptime T: type, list: *std.ArrayList(T), gpa: std.mem.Allocator, want: usize) !void {
    try list.ensureTotalCapacity(gpa, want);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, list: *std.ArrayList(u64)) !void {
    try reserve(u64, list, gpa, try r.takeInt(u32, .little));
}
