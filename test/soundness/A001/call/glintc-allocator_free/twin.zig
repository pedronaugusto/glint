// A001: a slice of governed ids freed: an allocator's free reads no value's fields or bytes
// (lookout's Inotify, review b9).
const std = @import("std");
const aegis = @import("aegis");
const WatchId = aegis.id.Id(enum { watch }, u32);
pub fn drop(gpa: std.mem.Allocator, owners: []WatchId) void {
    gpa.free(owners);
}
