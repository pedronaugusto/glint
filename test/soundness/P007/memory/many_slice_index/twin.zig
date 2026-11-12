// P007: the same through a slice, which carries its length.
pub fn f(s: []const u8) u8 {
    return s[5..6][0];
}
