// Z026: an empty catch before the function returns an error as its value
fn parse(s: []const u8) error{OutOfMemory}!void {
    if (s.len == 0) return error.OutOfMemory;
}
pub fn classify(s: []const u8) anyerror {
    parse(s) catch {};
    return error.Default;
}
