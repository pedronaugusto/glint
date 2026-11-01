// review 4: af/a5_twice.zig
const std = @import("std");
const Bytes = @import("aegis").SecretBytes;
pub fn f(gpa: std.mem.Allocator, n: usize) !void {
    const buffer = try gpa.alloc(u8, n);
    var a = try Bytes.adopt(buffer, n);
    a.deinit(gpa);
}
pub fn g(gpa: std.mem.Allocator, n: usize) ![2]Bytes {
    const buffer = try gpa.alloc(u8, n);
    return .{ try Bytes.adopt(buffer, n), try Bytes.adopt(buffer, n) };
}
