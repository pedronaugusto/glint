// The same type function bound with a number.
const std = @import("std");
const Type = type;
pub fn Box(comptime T: type) Type {
    return struct {
        held: T,
        pub fn get(self: *@This()) T {
            return self.held;
        }
    };
}
pub fn f() Box(u32) {
    return .{ .held = 1 };
}
