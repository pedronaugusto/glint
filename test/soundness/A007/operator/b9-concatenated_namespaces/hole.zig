// A007: std's atomic an element of tuples joined by ++, its raw cell made: a finding.
const aegis = @import("aegis");
const std = @import("std");
const both = .{std.mem} ++ .{std.atomic};
pub fn make() u32 {
    var cell: both[1].Value(u32) = .init(0);
    return cell.load(.monotonic);
}
