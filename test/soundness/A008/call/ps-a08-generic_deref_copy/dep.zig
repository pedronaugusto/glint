const std = @import("std");
// A dependency's generic that keeps a copy of what its pointer argument points at.
pub var last: [64]u8 = undefined;
pub fn remember(p: anytype) void {
    const copy = p.*;
    @memcpy(last[0..@sizeOf(@TypeOf(copy))], std.mem.asBytes(&copy));
}
