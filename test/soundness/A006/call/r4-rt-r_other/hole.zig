// review 4: rt/r_other.zig
const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
pub fn read(text: Text) error{TooDeep}!void {
    var p: Parser = .{ .bytes = text.readForParse() };
    try p.value();
}
const Counter = struct { n: u8 = 0 };
const Parser = struct {
    bytes: []const u8,
    depth: u8 = 0,
    fn value(p: *Parser) error{TooDeep}!void {
        var scratch: Counter = .{};
        scratch.n += 1;
        if (scratch.n > 64) return error.TooDeep;
        if (p.bytes.len == 0) return;
        p.bytes = p.bytes[1..];
        try p.value();
    }
};
