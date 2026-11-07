// A012 in a build script: a reader a call through a function pointer gives, which does not
// resolve: its source is not shown to be the build's, so the size stays flagged or undecided.
const std = @import("std");
pub fn sizes(gpa: std.mem.Allocator, open: *const fn () *std.Io.Reader) ![]u8 {
    const r = open();
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
