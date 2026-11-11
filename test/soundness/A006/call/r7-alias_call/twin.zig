const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
const This = @This();
fn leaf(x: []const u8) usize { return x.len; }
pub fn read(text: Text) usize {
    return nest(text.readForParse());
}
fn nest(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return 1 + @call(.auto, @field(This, "leaf"), .{bytes[1..]});
}
