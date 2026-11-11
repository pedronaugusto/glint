// Z026 twin: the errdefer's cleanup counts its error
fn fallible() error{Failure}!void {
    return error.Failure;
}
var failures: u32 = 0;
pub fn run() !void {
    errdefer if (fallible()) {} else |_| {
        failures += 1;
    };
    try fallible();
}
