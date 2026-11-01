// warp-fast: the type function is given a pointer to the lock: a borrow.
const std = @import("std");
fn Holder(comptime T: type) type {
    return struct { lock: T };
}
pub const Shared = Holder(*std.Io.Mutex);
