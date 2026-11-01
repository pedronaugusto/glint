// review 4: u/u16_labeled_switch_redispatch.zig
// A019: the .SUCCESS prong of a switch on errno(rc) is walked as "fstat wrote st", but a
// `continue :sw .SUCCESS` from the .INTR prong enters it after a failed call.
const std = @import("std");
extern "c" fn fstat(fd: c_int, buf: *std.c.Stat) c_int; // aegis: boundary(A019): libc
pub fn size(fd: c_int) i64 {
    var st: std.c.Stat = undefined;
    const rc = fstat(fd, &st);
    sw: switch (std.c.errno(rc)) {
        .SUCCESS => return st.size,
        .INTR => continue :sw .SUCCESS,
        else => return -1,
    }
}
