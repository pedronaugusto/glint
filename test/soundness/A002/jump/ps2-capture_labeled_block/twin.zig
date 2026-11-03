// A capture of a guard the call makes in place: the copy moves it, nothing else holds it.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) void {
    if (l.tryAcquire()) |g| {
        var copy = g;
        copy.deinit();
    }
}
