// P007: an index through a slice of a many-item pointer, past the index ban (review 8, C2).
pub fn f(p: [*]const u8) u8 {
    return p[5..6][0];
}
