// glint-c: a format's text argument from input: its length pads nothing a peer chooses
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const name = try r.take(8);
    var buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{s:>16}", .{name});
    return out.len;
}
