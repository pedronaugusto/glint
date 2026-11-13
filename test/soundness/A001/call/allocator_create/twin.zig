// A001: Allocator.create hands back storage for one value, written by the type's own maker.
const std = @import("std");
const aegis = @import("aegis");
const S = aegis.Secret([4]u8);
pub fn f(gpa: std.mem.Allocator) !*S {
    const p = try gpa.create(S);
    p.* = S.init(.{ 0, 0, 0, 0 });
    return p;
}
