// A002 call: the same generic handed a function that makes a bool: the comptime `if` on the
// function's type takes `decode(gpa)`, never `decode.run(gpa)`, and a bool copies as data
const std = @import("std");
fn acquire(comptime T: type, gpa: std.mem.Allocator, decode: anytype) !struct { a: T, b: T } {
    const result = if (comptime @typeInfo(@TypeOf(decode)) == .@"fn") decode(gpa) else decode.run(gpa);
    const value = try result;
    return .{ .a = value, .b = value };
}
fn mk(gpa: std.mem.Allocator) !bool {
    _ = gpa;
    return true;
}
pub fn f() !void {
    const both = try acquire(bool, std.heap.page_allocator, mk);
    _ = both;
}
