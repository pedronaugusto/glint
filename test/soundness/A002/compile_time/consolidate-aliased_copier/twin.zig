// consolidate: A002 compile_time (aliased copier): the record points at the owner, so the
// generic's copies through its alias are aliases, which A002 leaves out: must stay clean
const S = @import("aegis").Secret(u32);
const Holder = struct { s: *const S, n: u32 };
fn keep(comptime T: type, v: T) [2]T {
    return .{ v, v };
}
const k = keep;
pub fn f(s: *const S) void {
    const h: Holder = .{ .s = s, .n = 2 };
    _ = k(Holder, h);
}
