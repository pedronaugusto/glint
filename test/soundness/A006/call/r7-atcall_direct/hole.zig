const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
// The recursive call made through @call on the function itself.
pub fn read(text: Text) usize {
    return nest(text.readForParse());
}
fn nest(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return 1 + @call(.auto, nest, .{bytes[1..]});
}
