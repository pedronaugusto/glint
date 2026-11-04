// glint-b: A002 compile_time (held in a record): a generic that copies its parameter twice,
// bound to a record of the program holding an owner by value, copies the owner: must flag
const S = @import("aegis").Secret(u32);
const Holder = struct { s: S, n: u32 };
fn keep(comptime T: type, v: T) [2]T {
    return .{ v, v };
}
pub fn f() void {
    const h: Holder = .{ .s = S.init(1), .n = 2 };
    _ = keep(Holder, h);
}
