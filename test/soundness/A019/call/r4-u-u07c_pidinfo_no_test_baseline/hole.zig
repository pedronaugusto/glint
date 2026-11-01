// review 4: u/u07c_pidinfo_no_test_baseline.zig
// baseline: no test of rc (expected flagged)
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int; // aegis: boundary(A019): libproc
pub fn f(pid: c_int) u8 {
    var buf: [64]u8 = undefined;
    _ = proc_pidinfo(pid, 3, 0, &buf, 8);
    return buf[63];
}
