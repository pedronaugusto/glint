// Z043 twin: the same done the way the rule leaves
pub fn first(s: []const u8) u8 {
    for (s) |b| {
        if (b != 0) return b;
    }
    return 0;
}
