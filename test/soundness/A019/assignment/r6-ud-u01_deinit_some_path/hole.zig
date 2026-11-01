// review 6: ud/u01_deinit_some_path.zig
const std = @import("std");
const aegis = @import("aegis");
// The owner is released on one path only, then read: a read of undefined memory where c is true.
pub fn f(gpa: std.mem.Allocator, c: bool) !usize {
    var s = try aegis.SecretBytes.init(gpa, 16);
    if (c) s.deinit(gpa);
    const n = s.len();
    if (!c) s.deinit(gpa);
    return n;
}
