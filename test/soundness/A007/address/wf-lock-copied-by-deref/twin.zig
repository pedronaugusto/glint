// warp-fast: a local keeps the pointer the caller lends: a borrow.
const std = @import("std");
pub fn f(p: *std.Io.Mutex) void {
    const lent = p;
    _ = lent;
}
