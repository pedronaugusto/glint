// review 6: ud/u03_release_in_callee.zig
const std = @import("std");
const aegis = @import("aegis");
fn drop(s: *aegis.SecretBytes, gpa: std.mem.Allocator) void {
    s.deinit(gpa);
}
// A callee releases it; the read after is of undefined memory.
pub fn f(gpa: std.mem.Allocator) !usize {
    var s = try aegis.SecretBytes.init(gpa, 16);
    drop(&s, gpa);
    return s.len();
}
