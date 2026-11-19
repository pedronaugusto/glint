// P007: arithmetic on a slice's .ptr, a many-item pointer that carries no length to check
pub fn second(b: []const u8) u8 {
    const p = b.ptr + 1;
    return p[0];
}
