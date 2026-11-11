const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
// The untrusted input waits in a container var; the function that parses it takes no parameter.
pub var inbox: Text = .init("");
pub fn run() usize {
    return nest(inbox.readForParse());
}
fn nest(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return 1 + nest(bytes[1..]);
}
