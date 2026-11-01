// review 4: u/u16b_baseline_no_redispatch.zig
// baseline: the .INTR prong reads st itself (expected flagged)
const std = @import("std");
extern "c" fn fstat(fd: c_int, buf: *std.c.Stat) c_int; // aegis: boundary(A019): libc
pub fn size(fd: c_int) i64 {
    var st: std.c.Stat = undefined;
    const rc = fstat(fd, &st);
    switch (std.c.errno(rc)) {
        .SUCCESS => return st.size,
        .INTR => return st.size,
        else => return -1,
    }
}
