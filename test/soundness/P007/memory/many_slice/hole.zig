// P007: a many-item pointer sliced: the length is the program's word, unchecked (review 8, C2).
pub fn f(p: [*]const u8, n: usize) []const u8 {
    return p[0..n];
}
