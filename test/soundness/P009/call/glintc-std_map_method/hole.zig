// P009: a std map's method given a key that slices a local stores it in the map returned.
const std = @import("std");
pub fn f(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    var name: [1]u8 = .{'a'};
    try map.put(&name, "b");
    return map;
}
