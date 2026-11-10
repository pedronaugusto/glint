// A009 conversion: an untagged union with a member that holds a table's own id reads another
// member's bytes as the id: the position it reaches may name no entry.
const std = @import("std");

const Entry = struct {
    name: u8,
    pub const Id = enum(u32) { _ };
};

const Either = extern union { raw: u32, id: Entry.Id };

pub fn f(r: *std.Io.Reader, entries: []const Entry) !u8 {
    const either: Either = .{ .raw = try r.takeInt(u32, .little) };
    return entries[@backingInt(either.id)].name;
}
