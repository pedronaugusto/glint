// A002 call: a generic copies what a function it is handed makes, read through a comptime
// `if` on that function's type; handed one that makes a Secret, the copy duplicates it
const std = @import("std");
const S = @import("aegis").Secret(u32);
fn acquire(comptime T: type, gpa: std.mem.Allocator, decode: anytype) !struct { a: T, b: T } {
    const result = if (comptime @typeInfo(@TypeOf(decode)) == .@"fn") decode(gpa) else decode.run(gpa);
    const value = try result;
    return .{ .a = value, .b = value };
}
fn mk(gpa: std.mem.Allocator) !S {
    _ = gpa;
    return S.init(1);
}
pub fn f() !void {
    const both = try acquire(S, std.heap.page_allocator, mk);
    _ = both;
}
