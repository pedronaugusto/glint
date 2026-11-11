// Z026: an empty error branch in a file only a test imports: production code all the same
fn lock(path: []const u8) error{AccessDenied}!void {
    if (path.len == 0) return error.AccessDenied;
}
pub fn main() !void {
    if (lock("state")) |_| return error.AlreadyLocked else |_| {}
}
