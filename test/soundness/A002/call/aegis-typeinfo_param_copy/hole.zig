// aegis A002 probe (shakedown sim/fs/calls.zig's shape): a generic makes a function whose parameter is typed
// by @typeInfo of the function type it is bound to, and hands what that parameter points at, by value, to a
// generic that copies its parameter; bound to a pointer to a live guard, the guard is duplicated.
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
    Route(fn (*L.Guard) void).f(&g);
}
