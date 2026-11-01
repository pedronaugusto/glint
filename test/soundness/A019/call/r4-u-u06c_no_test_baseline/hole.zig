// review 4: u/u06c_no_test_baseline.zig
// baseline: pid read with no test of rc (expected flagged)
const std = @import("std");
pub fn spawn(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) std.c.pid_t {
    var pid: std.c.pid_t = undefined;
    const rc = std.c.posix_spawn(&pid, "/bin/true", null, null, argv, envp);
    _ = rc;
    return pid;
}
