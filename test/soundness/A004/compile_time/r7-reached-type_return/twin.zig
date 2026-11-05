// The same generic bound to Plain only: `if (T == Plain) return` leaves before the cast
const Plain = struct { v: u32 };
fn value(comptime T: type, v: u32) T {
    if (T == Plain) return .{ .v = v };
    return @fromBackingInt(@intCast(v));
}
pub fn f(v: u32) Plain {
    return value(Plain, v);
}
