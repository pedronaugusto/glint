const aegis = @import("aegis");
const Text = aegis.input.Untrusted([]const u8);
const Request = struct { body: Text };
pub fn read(req: Request) error{TooDeep}!usize {
    return nest(req.body.readForParse(), 0);
}
fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize {
    if (depth > 64) return error.TooDeep;
    if (bytes.len == 0) return 0;
    return 1 + try nest(bytes[1..], depth + 1);
}
