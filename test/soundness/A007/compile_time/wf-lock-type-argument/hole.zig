// warp-fast: a type function makes a field that holds the lock type it is given by value.
const std = @import("std");
fn Holder(comptime T: type) type {
    return struct { lock: T };
}
pub const Shared = Holder(std.Io.Mutex);
