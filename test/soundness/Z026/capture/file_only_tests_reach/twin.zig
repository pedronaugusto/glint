// Z026 twin: the same empty error branch written inside a test block
fn lock(path: []const u8) error{AccessDenied}!void {
    if (path.len == 0) return error.AccessDenied;
}
pub fn main() !void {
    try lock("state");
}
test "lock refuses an empty path" {
    if (lock("")) |_| return error.TestUnexpectedResult else |_| {}
}
