// glint-b: A001 memory (bytes read): the same shape made safe, which must stay clean
const std = @import("std");
const Plain = struct { material: u64 };
pub fn f(s: *const Plain) [8]u8 {
    return std.mem.toBytes(s.*);
}
