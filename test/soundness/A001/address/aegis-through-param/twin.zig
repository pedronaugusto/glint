const std = @import("std");
const err = @import("aegis").err;
const Holder = struct { source: err.PublicSource };
// The source's bytes read through a pointer to `const`: nothing is written through it.
pub fn f(h: *const Holder) usize {
    return std.mem.asBytes(&h.source).len;
}
