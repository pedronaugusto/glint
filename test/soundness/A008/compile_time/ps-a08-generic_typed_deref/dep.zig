const std = @import("std");
// A dependency's generic over a type that names it only behind a pointer, and copies what the pointer points at.
pub fn sum(comptime T: type, p: *const T) u32 {
    const copy = p.*;
    var total: u32 = 0;
    for (std.mem.asBytes(&copy)) |b| total += b;
    return total;
}
