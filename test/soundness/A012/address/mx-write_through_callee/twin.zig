// matrix: a callee writes input through the pointer it is given, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
fn readSize(out: *u32, r: *std.Io.Reader) !void {
    out.* = try r.takeInt(u32, .little);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    try readSize(&n, r);
    try limit.check(n);
    return gpa.alloc(u8, n);
}
