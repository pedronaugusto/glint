// A009 conversion: the same std generic bound to a plain number makes no id, and an id counted
// over the table names an entry: the cast inside std is no source of this table's ids.
const std = @import("std");

const Entry = struct {
    name: u8,
    pub const Id = enum(u32) { _ };
};

pub fn f(r: *std.Io.Reader, entries: []const Entry) !u8 {
    const bytes = try r.takeArray(4);
    const want = std.mem.bytesToValue(u32, bytes);
    for (entries, 0..) |entry, i| {
        if (entry.name != want) continue;
        const id: Entry.Id = @fromBackingInt(@intCast(i));
        return entries[@backingInt(id)].name;
    }
    return 0;
}
