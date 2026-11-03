// The generic hands its parameter to std's append once.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn one(x: anytype, list: *std.ArrayList(@TypeOf(x))) void {
    list.appendAssumeCapacity(x);
}
pub fn g(l: *L) void {
    var buf: [1]L.Guard = undefined;
    var list: std.ArrayList(L.Guard) = .initBuffer(&buf);
    one(l.acquire(), &list);
    for (list.items) |*held| held.deinit();
}
