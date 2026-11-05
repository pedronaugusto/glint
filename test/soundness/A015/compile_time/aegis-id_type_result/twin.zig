// The same generic bound with a number: its call is a value, and f returns no resource.
const std = @import("std");
pub fn Id(comptime T: type, comptime v: T) T {
    return v;
}
const size = Id(usize, 4);
pub fn f() [size]u8 {
    return @splat(0);
}
