// glint-c: a method of an `anytype` parameter's value makes what its binding's type gives:
// a count, which owes no release.
const std = @import("std");
const Counter = struct {
    n: u32,
    pub fn next(counter: Counter) u32 {
        return counter.n + 1;
    }
};
pub fn step(counter: anytype) u32 {
    const n = counter.next();
    return n;
}
pub fn f() u32 {
    return step(Counter{ .n = 1 });
}
