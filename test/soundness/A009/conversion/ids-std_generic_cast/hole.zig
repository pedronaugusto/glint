// A009 conversion: std's bytesToValue, a generic the program binds to a table's own id, makes one
// from a peer's bytes by a cast inside std: the position it reaches may name no entry.
const std = @import("std");

const Entry = struct {
    name: u8,
    pub const Id = enum(u32) { _ };
};

pub fn f(r: *std.Io.Reader, entries: []const Entry) !u8 {
    const bytes = try r.takeArray(4);
    const id = std.mem.bytesToValue(Entry.Id, bytes);
    return entries[@backingInt(id)].name;
}
