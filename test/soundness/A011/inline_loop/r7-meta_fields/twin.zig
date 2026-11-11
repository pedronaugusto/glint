const std = @import("std");
const P = struct { nanoseconds: i96 };
pub fn f(d: P) i96 {
    var sum: i96 = 0;
    inline for (@typeInfo(P).@"struct".field_names) |n| sum += @field(d, n);
    return sum;
}
