// glint-b: a record holding a record that holds a guard (relic's LockFile in a Transaction): the
// outer deinit releases it through the inner record's deinit, on every exit.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct {
    guard: L.Guard,
    fn deinit(h: *Held) void {
        h.guard.deinit();
    }
};
const Outer = struct {
    inner: Held,
    count: u32,
    fn deinit(o: *Outer) void {
        o.inner.deinit();
        o.count = 0;
    }
};
fn open(l: *L) Outer {
    return .{ .inner = .{ .guard = l.acquire() }, .count = 1 };
}
pub fn f(l: *L) u32 {
    var outer = open(l);
    defer outer.deinit();
    outer.count += 1;
    return outer.count;
}
