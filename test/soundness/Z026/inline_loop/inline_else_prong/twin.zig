// Z026 twin: the inline else prong counts the error
var misses: u32 = 0;
fn fetch(n: u32) error{ Missing, Stale }!u32 {
    if (n == 0) return error.Missing;
    if (n == 1) return error.Stale;
    return n;
}
pub fn warm(n: u32) void {
    _ = fetch(n) catch |e| switch (e) {
        inline else => {
            misses += 1;
        },
    };
}
