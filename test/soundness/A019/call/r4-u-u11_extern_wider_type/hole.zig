// review 4: u/u11_extern_wider_type.zig
// A019: the program's own extern fstat declared with a 4096-byte buffer; fstat writes sizeof(struct stat) only.
extern "c" fn fstat(fd: c_int, buf: *[4096]u8) c_int; // aegis: boundary(A019): libc
pub fn f(fd: c_int) u8 {
    var buf: [4096]u8 = undefined;
    if (fstat(fd, &buf) != 0) return 0;
    return buf[4095];
}
