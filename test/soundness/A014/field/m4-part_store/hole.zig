// glint-c: A014 field: a struct local's part is given the frame's address after its init, and the struct is returned
const View = struct { bytes: []const u8, n: usize };
pub fn view() View {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    var out: View = .{ .bytes = &.{}, .n = 0 };
    out.bytes = &buf;
    out.n = 4;
    return out;
}
