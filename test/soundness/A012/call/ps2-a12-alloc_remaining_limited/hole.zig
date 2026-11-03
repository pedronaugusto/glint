// std's allocRemaining allocates up to a limit a peer chose: its summary holds the limit both
// kept to a range (the bytes appended, measured by toOwnedSlice) and through the reader's
// vtable (does not resolve); the range wins and the site reads as data.
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return r.allocRemaining(gpa, .limited(n));
}
