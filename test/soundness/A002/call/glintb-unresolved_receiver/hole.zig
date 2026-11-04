// glint-b: A002 call (an unresolved receiver): `access` is of no known type, so `access.write` may be
// the program's generic that copies its parameter; handed an owner, it may copy it: must not be clean
const S = @import("aegis").Secret(u32);
fn write(comptime T: type, value: T) [2]T {
    return .{ value, value };
}
pub fn use() void {
    _ = write(u32, 1);
}
pub fn serialize(owned: *S, access: anytype) void {
    _ = access.write(S, owned.*);
}
