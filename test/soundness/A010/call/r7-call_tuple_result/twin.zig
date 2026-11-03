const std = @import("std");
fn read1(r: *std.Io.Reader) !u64 {
    _ = r;
    return 7;
}
pub fn f(r: *std.Io.Reader) !u64 {
    const v = try @call(.auto, read1, .{r});
    return v * 3;
}
