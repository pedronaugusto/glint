// P009: std's Environ.Map.put given a key that slices a local keeps a copy of it (`gpa.dupe`,
// written over what getOrPut stored; the entry popped on failure): the map returned holds no
// address into the frame.
const std = @import("std");
pub fn f(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    var name: [1]u8 = .{'a'};
    try map.put(&name, "b");
    return map;
}
