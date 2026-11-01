// matrix: a size from input stored in a field through the caller's pointer, then allocated
const std = @import("std");
const State = struct { want: u32 = 0 };
pub fn f(s: *State, r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    s.want = try r.takeInt(u32, .little);
    return gpa.alloc(u8, s.want);
}
