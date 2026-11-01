// review 4: u/u06b_errno_posix_spawn_switch.zig
// A019: the same through a switch on errno(rc) with a .SUCCESS prong.
const std = @import("std");
pub fn spawn(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) std.c.pid_t {
    var pid: std.c.pid_t = undefined;
    const rc = std.c.posix_spawn(&pid, "/bin/true", null, null, argv, envp);
    switch (std.c.errno(rc)) {
        .SUCCESS => return pid,
        else => return -1,
    }
}
