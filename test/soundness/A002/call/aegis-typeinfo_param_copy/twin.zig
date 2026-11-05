// aegis A002 probe's twin: the same function made over a pointer to a number copies no guard.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn invoke(args: anytype) void {
    const copy = args;
    _ = copy;
}
fn Route(comptime F: type) type {
    const params = @typeInfo(F).@"fn".param_types;
    return struct {
        fn f(a: params[0].?) void {
            invoke(.{a.*});
        }
    };
}
pub fn run(l: *L) void {
    var g = l.acquire();
    defer g.deinit();
    var n: u32 = g.value().*;
    Route(fn (*u32) void).f(&n);
}
