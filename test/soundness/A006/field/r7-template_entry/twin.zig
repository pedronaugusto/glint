const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
// The same type function bound to plain bytes the program made: no untrusted input reaches it.
fn Request(comptime Body: type) type {
    return struct {
        const Self = @This();
        body: Body,
        pub fn read(self: *const Self) usize {
            return nest(self.body);
        }
    };
}
pub fn serve(req: *const Request([]const u8)) usize {
    return req.read();
}
fn nest(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return 1 + nest(bytes[1..]);
}
