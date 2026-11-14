// Z026: a switch over the error whose every prong is empty drops the error it names.
fn fallible() error{Failure}!u8 {
    return error.Failure;
}
pub fn run() u8 {
    return fallible() catch |err| switch (err) {
        error.Failure => 0,
    };
}
pub fn drop() void {
    _ = fallible() catch |err| switch (err) {
        error.Failure => {},
    };
}
