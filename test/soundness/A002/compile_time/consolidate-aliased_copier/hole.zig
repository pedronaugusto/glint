// consolidate: A002 compile_time (aliased copier): a generic that copies its parameter twice,
// called through a constant that names it, bound to a record holding an owner by value, copies
// the owner: must flag (a callee read by its spelling, `k`, found no copier of that name)
const S = @import("aegis").Secret(u32);
const Holder = struct { s: S, n: u32 };
fn keep(comptime T: type, v: T) [2]T {
    return .{ v, v };
}
const k = keep;
pub fn f() void {
    const h: Holder = .{ .s = S.init(1), .n = 2 };
    _ = k(Holder, h);
}
