// matrix A010 branch: an if expression chooses the input on one side
const std = @import("std");
pub fn f(r: *std.Io.Reader, wide: bool) !u64 {
    const v: u64 = if (wide) try r.takeInt(u64, .little) else 1;
    return v * 1000;
}
