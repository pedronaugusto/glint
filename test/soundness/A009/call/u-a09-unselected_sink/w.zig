// An import of the case's, not selected: it indexes memory with what it is given.
pub fn pick(buf: []const u8, i: usize) u8 {
    return buf[i];
}
