// review 6: ud/u01b_deinit_straight.zig
const std = @import("std");
const aegis = @import("aegis");
pub fn f(gpa: std.mem.Allocator) !usize {
    var s = try aegis.SecretBytes.init(gpa, 16);
    s.deinit(gpa);
    return s.len();
}
