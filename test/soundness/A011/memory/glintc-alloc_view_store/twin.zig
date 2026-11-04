// The same view of integers an allocator gives, as other integers: a count stored into a count.
const std = @import("std");
pub fn f(a: std.mem.Allocator, ns: i128) ![]u128 {
    const out = try a.alloc(u128, 1);
    const raw: []i128 = @ptrCast(out);
    raw[0] = ns;
    return out;
}
