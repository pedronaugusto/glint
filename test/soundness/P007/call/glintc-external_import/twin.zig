// P007 twin: the same call to a function written in the package's own Zig, which glint reads
fn getpid() c_int {
    return 1;
}
pub fn pid() c_int {
    return getpid();
}
