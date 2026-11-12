// P007: a slice sliced: its length bounds the new one.
pub fn f(s: []const u8, n: usize) []const u8 {
    return s[0..n];
}
