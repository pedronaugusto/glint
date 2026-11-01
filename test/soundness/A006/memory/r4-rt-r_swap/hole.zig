// review 4: rt/r_swap.zig
const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
pub fn read(text: Text) error{TooDeep}!usize {
    return nest(text.readForParse(), 0, 0);
}
fn nest(bytes: []const u8, depth: u8, other: u8) error{TooDeep}!usize {
    _ = other;
    if (depth > 64) return error.TooDeep;
    if (bytes.len == 0) return 0;
    return 1 + try nest(bytes[1..], 0, depth + 1);
}
