const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
// The entry takes the untrusted input inside a request struct.
const Request = struct { body: Text };
pub fn read(req: Request) error{TooDeep}!usize {
    return nest(req.body.readForParse());
}
fn nest(bytes: []const u8) error{TooDeep}!usize {
    if (bytes.len == 0) return 0;
    return 1 + try nest(bytes[1..]);
}
