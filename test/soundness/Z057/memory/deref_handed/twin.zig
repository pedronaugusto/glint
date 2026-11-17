// Z057 twin: the same done the way the rule leaves
const Read = struct { bytes: usize };
fn step(input: []const u8, at: *usize) !Read {
    if (at.* >= input.len) return error.EndOfInput;
    at.* += 1;
    return .{ .bytes = 1 };
}
pub fn skip(input: []const u8, at: *usize) !void {
    const read = try step(input, at);
    at.* += read.bytes;
}
