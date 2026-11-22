// A007: std's atomic named by a destructure, its raw cell reached through it: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn make() u32 {
    const atomic, const mem = .{ std.atomic, std.mem };
    _ = mem;
    var cell: atomic.Value(u32) = .init(0);
    return cell.load(.monotonic);
}
