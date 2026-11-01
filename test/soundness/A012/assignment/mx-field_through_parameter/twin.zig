// matrix: a size from input stored in a field through the caller's pointer, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const State = struct { want: u32 = 0 };
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(s: *State, r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    s.want = try r.takeInt(u32, .little);
    try limit.check(s.want);
    return gpa.alloc(u8, s.want);
}
