// review 4: u/u07_pidinfo_short_size.zig
// A019: proc_pidinfo told to fill 8 bytes answers 8; the other 56 bytes of the buffer are never written.
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int; // aegis: boundary(A019): libproc
pub fn f(pid: c_int) u8 {
    var buf: [64]u8 = undefined;
    const rc = proc_pidinfo(pid, 3, 0, &buf, 8);
    if (rc != 8) return 0;
    return buf[63];
}
