// The same var given a raw count's own address on each path: a store of a count into a count.
const std = @import("std");
pub fn f(ns: i96, early: bool) i96 {
    var d: i96 = 0;
    var raw: *i96 = &d;
    if (early) raw = &d;
    raw.* = ns;
    return d;
}
