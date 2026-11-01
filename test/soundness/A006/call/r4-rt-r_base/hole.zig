// review 4: rt/r_base.zig
const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
pub fn read(text: Text) error{TooDeep}!usize {
    return nest(text.readForParse(), 0);
}
fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize {
    if (bytes.len == 0) return 0;
    return 1 + try nest(bytes[1..], depth + 1);
}
