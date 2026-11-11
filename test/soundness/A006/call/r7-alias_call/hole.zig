const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
// The recursive call made through @call on @field of the file's own namespace.
const This = @This();
pub fn read(text: Text) usize {
    return nest(text.readForParse());
}
fn nest(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return 1 + @call(.auto, @field(This, "nest"), .{bytes[1..]});
}
