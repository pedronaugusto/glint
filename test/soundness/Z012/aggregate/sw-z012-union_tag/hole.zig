// A public signature's union written in place, tagged by a private enum.
const Tag = enum { a, b };
pub fn make() union(Tag) { a: u8, b: u16 } {
    return .{ .a = 1 };
}
