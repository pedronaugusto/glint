// Z043: the reported form
pub fn first(s: []const u8) u8 {
    for (s) |b| {
        return b;
    }
    return 0;
}
