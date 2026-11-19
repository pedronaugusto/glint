// Z026 twin: one prong answers its error
fn fallible() error{ Empty, Full }!void {
    return error.Empty;
}
var full: u32 = 0;
pub fn run() void {
    fallible() catch |err| switch (err) {
        error.Empty => {},
        error.Full => full += 1,
    };
}
