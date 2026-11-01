// review 4: u/u06_errno_posix_spawn.zig
// A019: posix_spawn answers an error number, never -1; std.c.errno(rc) is .SUCCESS for every rc != -1,
// so this test does not show pid written (EAGAIN = 35 passes it with pid untouched).
const std = @import("std");
pub fn spawn(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) std.c.pid_t {
    var pid: std.c.pid_t = undefined;
    const rc = std.c.posix_spawn(&pid, "/bin/true", null, null, argv, envp);
    if (std.c.errno(rc) != .SUCCESS) return -1;
    return pid;
}
