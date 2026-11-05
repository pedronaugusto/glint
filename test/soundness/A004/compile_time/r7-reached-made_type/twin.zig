// The same generic, its cast passed by for an aegis Id: `if (T == Index) return` makes the Id
// by its own constructor before the cast, so only the plain binding reaches the cast.
const Plain = enum(u32) { _ };
const Index = @import("aegis").id.Id(struct {}, u32);
fn value(comptime T: type, v: u32) T {
    if (T == Index) return Index.fromRaw(v);
    return @fromBackingInt(@intCast(v));
}
pub fn f(v: u32) Index {
    return value(Index, v);
}
pub fn g(v: u32) Plain {
    return value(Plain, v);
}
