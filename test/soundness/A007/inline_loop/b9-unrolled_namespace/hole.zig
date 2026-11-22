// A007: std's atomic an unrolled loop's capture, its raw cell made through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn make() u32 {
    var total: u32 = 0;
    inline for (.{std.atomic}) |atomic| {
        var cell: atomic.Value(u32) = .init(1);
        total += cell.load(.monotonic);
    }
    return total;
}
