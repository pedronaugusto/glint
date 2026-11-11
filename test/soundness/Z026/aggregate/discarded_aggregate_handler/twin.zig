// Z026 twin: the aggregate holding the error's number is stored
fn fallible() error{Failure}!void {
    return error.Failure;
}
var last: struct { u16 } = .{0};
pub fn run() void {
    fallible() catch |err| {
        last = .{@intFromError(err)};
    };
}
