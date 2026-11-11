const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
pub var inbox: Text = .init("");
pub fn run() usize {
    return nest(inbox.readForParse(), 0);
}
fn nest(bytes: []const u8, depth: u8) usize {
    if (depth > 64) return 0;
    if (bytes.len == 0) return 0;
    return 1 + nest(bytes[1..], depth + 1);
}
