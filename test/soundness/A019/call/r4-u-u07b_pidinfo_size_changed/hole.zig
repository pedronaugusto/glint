// review 4: u/u07b_pidinfo_size_changed.zig
// A019: the size compared is a var reassigned between the call and the test (rc 0 = failure passes).
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int; // aegis: boundary(A019): libproc
pub fn f(pid: c_int) u8 {
    var buf: [64]u8 = undefined;
    var size: c_int = 64;
    const rc = proc_pidinfo(pid, 3, 0, &buf, size);
    size = 0;
    if (rc != size) return 0;
    return buf[63];
}
