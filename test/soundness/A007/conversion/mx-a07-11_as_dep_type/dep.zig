const std = @import("std");
pub fn Cell(comptime T: type) type {
    return std.atomic.Value(T);
}
