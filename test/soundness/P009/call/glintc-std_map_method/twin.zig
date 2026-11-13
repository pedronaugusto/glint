// P009: a std map's method (its address bound as the receiver) given the caller's strings: no
// frame address reaches the map returned (conduit environ.zig, child/contract.zig).
const std = @import("std");
pub fn f(gpa: std.mem.Allocator, name: []const u8, value: []const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    try map.put(name, value);
    return map;
}
