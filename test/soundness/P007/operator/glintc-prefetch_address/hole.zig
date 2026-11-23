// P007: the same addresses, read through.
pub fn f(table: [*]u32, h: usize, bucket: []u32) u32 {
    const at = &table[h];
    return at.* + (bucket.ptr + 16)[0];
}
