// matrix A010 branch: input decides between two constants
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const v: u64 = if (try r.takeInt(u64, .little) > 3) 7 else 1;
    return v * 1000;
}
