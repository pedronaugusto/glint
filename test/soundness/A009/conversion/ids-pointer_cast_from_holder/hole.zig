// A009 conversion: a pointer to memory that holds a table's own id cast to bytes lets a peer's
// bytes be written over the id: the position it reaches may name no entry.
const std = @import("std");

const Entry = struct {
    name: u8,
    pub const Id = enum(u32) { _ };
};

pub fn f(r: *std.Io.Reader, entries: []const Entry) !u8 {
    var id: Entry.Id = @fromBackingInt(0);
    const bytes: *[4]u8 = @ptrCast(&id);
    try r.readSliceAll(bytes);
    return entries[@backingInt(id)].name;
}
