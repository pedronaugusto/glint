// Z057: the reported form
const Read = struct { bytes: usize };
fn step(input: []const u8, at: *usize) !Read {
    if (at.* >= input.len) return error.EndOfInput;
    at.* += 1;
    return .{ .bytes = 1 };
}
pub fn skip(input: []const u8, at: *usize) !void {
    at.* += (try step(input, at)).bytes;
}
