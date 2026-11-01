// review 4: rt/r_reset.zig
const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
pub fn read(text: Text) error{TooDeep}!void {
    var p: Parser = .{ .bytes = text.readForParse() };
    try p.value();
}
const Parser = struct {
    bytes: []const u8,
    depth: u8 = 0,
    fn value(p: *Parser) error{TooDeep}!void {
        p.depth += 1;
        if (p.depth > 64) return error.TooDeep;
        p.depth = 0;
        if (p.bytes.len == 0) return;
        p.bytes = p.bytes[1..];
        try p.value();
    }
};
