const std = @import("std");
const aegis = @import("aegis");
// std.meta.eql compares two guarded values field by field, no guard held.
pub fn f(a: *const aegis.Guarded(u32), b: *const aegis.Guarded(u32)) bool {
    return std.meta.eql(a.*, b.*);
}
