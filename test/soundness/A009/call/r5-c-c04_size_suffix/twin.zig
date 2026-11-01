// review 5: c/c04_size_suffix.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const text = try r.take(8);
    const x = try std.fmt.parseIntSizeSuffix(text, 10);
    return x * 2;
}
