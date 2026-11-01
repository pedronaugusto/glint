// matrix: A021 compile_time: two locks ranked by two separate Orders, so neither Order ranks one against the other: two tasks taking them in two orders deadlock
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.BlockingGuarded(u32);
const First = aegis.Order(&.{.{ .name = "a" }});
const Second = aegis.Order(&.{.{ .name = "b" }});
const A = First.Ordered(L, 0);
const B = Second.Ordered(L, 0);
pub fn both(a: *A, b: *B, ca: *First.Context, cb: *Second.Context, io: std.Io) void {
    var ga = a.acquireOrderedUncancelable(io, ca);
    defer ga.deinit(io);
    var gb = b.acquireOrderedUncancelable(io, cb);
    defer gb.deinit(io);
}
