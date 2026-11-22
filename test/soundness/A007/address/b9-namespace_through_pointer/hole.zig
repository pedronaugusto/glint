// A007: std's atomic reached through a pointer to it, its raw cell made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const atomic = &std.atomic;
pub fn make() u32 {
    var cell: atomic.*.Value(u32) = .init(0);
    return cell.load(.monotonic);
}
