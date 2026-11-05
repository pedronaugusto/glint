// A generic's cast past `if (T != Index) return`, bound to the aegis Id itself: `Index` named
// in the generic and at the binding is one type, so the binding reaches the cast.
const Plain = enum(u32) { _ };
const Index = @import("aegis").id.Id(struct {}, u32);
fn value(comptime T: type, v: u32) T {
    if (T != Index) return @fromBackingInt(@intCast(v));
    return @fromBackingInt(@intCast(v));
}
pub fn f(v: u32) Index {
    return value(Index, v);
}
pub fn g(v: u32) Plain {
    return value(Plain, v);
}
