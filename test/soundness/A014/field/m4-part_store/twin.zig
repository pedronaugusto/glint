// glint-c: A014 field: a struct local's part is given its caller's memory after its init, and the struct is returned
const View = struct { bytes: []const u8, n: usize };
pub fn view(given: []const u8) View {
    var out: View = .{ .bytes = &.{}, .n = 0 };
    out.bytes = given;
    out.n += given.len;
    return out;
}
