// review 6: ud/u01c_list_some_path.zig
const std = @import("std");
// A std list (no aegis owner): A003 does not follow it, so A019 reads it.
pub fn f(gpa: std.mem.Allocator, c: bool) !usize {
    var s: std.ArrayList(u8) = .empty;
    try s.append(gpa, 1);
    if (c) s.deinit(gpa);
    const n = s.items.len;
    if (!c) s.deinit(gpa);
    return n;
}
