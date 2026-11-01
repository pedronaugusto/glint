// review 6: ud/u04_method_release.zig
const std = @import("std");
const aegis = @import("aegis");
// A method other than deinit that gives the owner `undefined`: moveInto.
pub fn f(gpa: std.mem.Allocator) !usize {
    var s = try aegis.SecretBytes.init(gpa, 16);
    var t = try aegis.SecretBytes.init(gpa, 16);
    defer t.deinit(gpa);
    s.moveInto(&t);
    return s.len();
}
