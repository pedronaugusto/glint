const std = @import("std");
// std's Duration's fields read by reflection.
pub fn f(d: std.Io.Duration) i96 {
    var sum: i96 = 0;
    inline for (@typeInfo(std.Io.Duration).@"struct".field_names) |n| sum += @field(d, n);
    return sum;
}
