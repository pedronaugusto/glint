// twin: the block's fall-through returns an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    const at = blk: {
        for (line, 0..) |b, i| {
            if (b == ':') break :blk i;
        }
        return error.NoColon;
    };
    return at;
}
