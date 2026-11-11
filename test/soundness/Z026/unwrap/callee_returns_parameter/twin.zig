// Z026 twin: the catch counts the error
fn rethrow(failure: anyerror) !void {
    return failure;
}
var failures: u32 = 0;
pub fn run() void {
    rethrow(error.OutOfMemory) catch {
        failures += 1;
    };
}
