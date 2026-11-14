// Z026: a switch with no prongs over an empty error set handles nothing: it compiles only where
// no error can reach it, the compiler's proof that nothing fails (lookout's Poll.init, which stays
// an error union for the backend switch's `try`; tycho-b9's report, 8i).
fn infallible() error{}!u8 {
    return 1;
}
pub fn run() u8 {
    return infallible() catch |err| switch (err) {};
}
