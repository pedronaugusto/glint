// A generic hands its parameter to std's append twice: the list holds two guards of one lock,
// and each is released.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn dup(x: anytype, list: *std.ArrayList(@TypeOf(x))) void {
    list.appendAssumeCapacity(x);
    list.appendAssumeCapacity(x);
}
pub fn g(l: *L) void {
    var buf: [2]L.Guard = undefined;
    var list: std.ArrayList(L.Guard) = .initBuffer(&buf);
    dup(l.acquire(), &list);
    for (list.items) |*one| one.deinit();
}
