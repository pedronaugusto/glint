// P007: std.posix's portable types and constants, which it takes from the binding, are no member of it.
const std = @import("std");
pub fn f(e: std.posix.E) bool {
    return e == std.posix.E.AGAIN or e == std.posix.E.INTR;
}
