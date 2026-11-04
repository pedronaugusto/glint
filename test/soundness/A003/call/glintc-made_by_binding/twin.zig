// glint-c: a method of a value a type parameter types (`probe.of`) makes what this binding's
// type gives: a plain tag, which owes no release.
const std = @import("std");
const Probed = enum { is, none };
const Probe = struct {
    key: u32,
    pub fn of(probe: Probe, n: u32) Probed {
        return if (probe.key == n) .is else .none;
    }
};
pub fn count(comptime P: type, probe: P, n: u32) u32 {
    switch (probe.of(n)) {
        .is => return 1,
        .none => return 0,
    }
}
pub fn f(n: u32) u32 {
    return count(Probe, .{ .key = 1 }, n);
}
