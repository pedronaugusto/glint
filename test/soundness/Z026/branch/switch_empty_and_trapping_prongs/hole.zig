// Z026: a switch on the error whose prongs are empty or trap: every error dropped or trapped
fn fallible() error{ Empty, Full }!void {
    return error.Empty;
}
pub fn run() void {
    fallible() catch |err| switch (err) {
        error.Empty => {},
        error.Full => unreachable,
    };
}
