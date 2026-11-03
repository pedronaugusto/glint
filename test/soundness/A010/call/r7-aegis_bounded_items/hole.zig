// A010: the peer's numbers copied into an aegis bounded.Array are read back by items(): a product of one overflows
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader) !u64 {
    var held: aegis.bounded.Array(u64, 4) = .init;
    const v = try r.takeInt(u64, .little);
    try held.appendSlice(&.{v});
    return held.items()[0] * 3;
}
