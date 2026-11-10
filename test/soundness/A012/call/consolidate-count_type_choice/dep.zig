const std = @import("std");
const builtin = @import("builtin");
/// An integer in every build: u32 on one target, u64 on the others.
pub const Count = if (builtin.os.tag == .windows) u32 else u64;
pub fn fill(w: *std.Io.Writer, n: Count) !void {
    for (0..n) |_| try w.writeAll("ab");
}
