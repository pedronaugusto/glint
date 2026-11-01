// review 6: ud/u02_deinit_in_loop.zig
const std = @import("std");
const aegis = @import("aegis");
// Released in a loop pass, read on the next pass.
pub fn f(gpa: std.mem.Allocator, k: usize) !usize {
    var s = try aegis.SecretBytes.init(gpa, 16);
    var total: usize = 0;
    var i: usize = 0;
    while (i < k) : (i += 1) {
        total += s.len();
        if (i == 3) s.deinit(gpa);
    }
    return total;
}
