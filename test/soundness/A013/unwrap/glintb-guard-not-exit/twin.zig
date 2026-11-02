// glint-b: a `.?` in the right side of `x == null or`: only reached where it is not null
const std = @import("std");
pub fn f(r: *std.Io.Reader) !bool {
    const line = try r.take(16);
    const found = std.mem.indexOfScalar(u8, line, '\n');
    return found == null or found.? > 3;
}
