const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
// A type function's instance holds the untrusted input: its method recurses on it unbounded.
fn Request(comptime Body: type) type {
    return struct {
        const Self = @This();
        body: Body,
        pub fn read(self: *const Self) usize {
            return nest(self.body.readForParse());
        }
    };
}
pub fn serve(req: *const Request(Text)) usize {
    return req.read();
}
fn nest(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return 1 + nest(bytes[1..]);
}
