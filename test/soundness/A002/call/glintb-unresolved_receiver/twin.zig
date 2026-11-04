// glint-b: A002 call (an unresolved receiver): whatever `write` is, it is handed only plain
// data (numbers, bytes, a cast number, an array of them), which no binding copies an owner of: must stay clean
fn write(comptime T: type, value: T) [2]T {
    return .{ value, value };
}
pub fn use() void {
    _ = write(u32, 1);
}
pub fn serialize(n: u64, text: []const u8, access: anytype) void {
    _ = access.write(u64, n);
    _ = access.write([]const u8, text);
    _ = access.write(u8, @as(u8, 3));
    _ = access.write([4]u8, .{ 1, 2, 3, 4 });
}
