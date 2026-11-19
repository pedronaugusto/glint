// Z026 twin: the comptime block beside a statement that counts the error
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() void {
    fallible() catch {
        comptime {}
        failures += 1;
    };
}
