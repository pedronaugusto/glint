// Z026 twin: the catch counts the error
fn parse(s: []const u8) error{OutOfMemory}!void {
    if (s.len == 0) return error.OutOfMemory;
}
var failures: u32 = 0;
pub fn classify(s: []const u8) anyerror {
    parse(s) catch {
        failures += 1;
    };
    return error.Default;
}
