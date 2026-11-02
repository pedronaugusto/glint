// The same, its type declared public.
pub const Tag = enum { a, b };
pub fn make() union(Tag) { a: u8, b: u16 } {
    return .{ .a = 1 };
}
