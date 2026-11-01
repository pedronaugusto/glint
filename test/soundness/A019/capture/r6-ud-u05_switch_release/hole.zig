// review 6: ud/u05_switch_release.zig
const std = @import("std");
const aegis = @import("aegis");
pub fn f(gpa: std.mem.Allocator, k: u8) !usize {
    var s = try aegis.SecretBytes.init(gpa, 16);
    switch (k) {
        0 => s.deinit(gpa),
        else => {},
    }
    const n = s.len();
    if (k != 0) s.deinit(gpa);
    return n;
}
