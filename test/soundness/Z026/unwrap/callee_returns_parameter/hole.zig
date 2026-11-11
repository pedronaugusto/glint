// Z026: an empty catch on a call that returns the error it is given
fn rethrow(failure: anyerror) !void {
    return failure;
}
pub fn run() void {
    rethrow(error.OutOfMemory) catch {};
}
