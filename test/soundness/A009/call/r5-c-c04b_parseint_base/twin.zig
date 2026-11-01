// review 5: c/c04b_parseint_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const text = try r.take(8);
    const x = try std.fmt.parseInt(usize, text, 10);
    return x * 2;
}
