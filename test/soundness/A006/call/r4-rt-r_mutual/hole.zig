// review 4: rt/r_mutual.zig
const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
pub fn read(text: Text) error{TooDeep}!usize {
    return outer(text.readForParse(), 0);
}
fn outer(bytes: []const u8, depth: u8) error{TooDeep}!usize {
    if (depth > 64) return error.TooDeep;
    if (bytes.len == 0) return 0;
    return 1 + try inner(bytes[1..], depth + 1);
}
fn inner(bytes: []const u8, depth: u8) error{TooDeep}!usize {
    _ = depth;
    if (bytes.len == 0) return 0;
    return 1 + try outer(bytes[1..], 0);
}
