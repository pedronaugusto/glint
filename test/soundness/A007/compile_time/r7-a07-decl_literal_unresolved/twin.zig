// review 7 A007: the same pick giving an enum, given its tag.
const std = @import("std");
const dep = @import("dep.zig");
pub fn run() bool {
    const k: dep.Pick(1) = .init;
    return k == .a;
}
