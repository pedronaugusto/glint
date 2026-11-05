// A generic's cast past `if (T == Plain) return`, bound to an aegis Id: the binding reaches it
const Plain = struct { v: u32 };
const Index = @import("aegis").id.Id(struct {}, u32);
fn value(comptime T: type, v: u32) T {
    if (T == Plain) return .{ .v = v };
    return @fromBackingInt(@intCast(v));
}
pub fn f(v: u32) Index {
    return value(Index, v);
}
