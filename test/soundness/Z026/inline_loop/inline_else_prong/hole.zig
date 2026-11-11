// Z026: an error caught and switched on, every error taken by an empty inline else prong
fn fetch(n: u32) error{ Missing, Stale }!u32 {
    if (n == 0) return error.Missing;
    if (n == 1) return error.Stale;
    return n;
}
pub fn warm(n: u32) void {
    _ = fetch(n) catch |e| switch (e) {
        inline else => {},
    };
}
