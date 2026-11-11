// Z026 twin: catch unreachable under a written reason
fn fallible(n: u8) error{Zero}!u8 {
    if (n == 0) return error.Zero;
    return n;
}
pub fn run() u8 {
    return fallible(1) catch unreachable; // glint-ignore: Z026 -- one is never zero
}
