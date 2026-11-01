// matrix: a size from input handed to the program's own wrapper, which checks it against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
fn buffer(gpa: std.mem.Allocator, len: usize) ![]u8 {
    try limit.check(len);
    return gpa.alloc(u8, len);
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    return buffer(gpa, try r.takeInt(u32, .little));
}
