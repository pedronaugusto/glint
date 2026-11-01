// c1: after before.zig, a loop of a constant bound
pub fn g(out: *u8) void {
    var i: usize = 0;
    while (i < 16) : (i += 1) out.* +%= 1;
}
