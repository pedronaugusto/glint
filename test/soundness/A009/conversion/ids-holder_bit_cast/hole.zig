// A009 conversion: a `@bitCast` to a struct that holds a table's own id makes the id from a
// peer's bytes without converting to it: the position it reaches may name no entry.
const std = @import("std");

const Entry = struct {
    name: u8,
    pub const Id = enum(u32) { _ };
};

const Ref = packed struct { id: Entry.Id };

pub fn f(r: *std.Io.Reader, entries: []const Entry) !u8 {
    const raw = try r.takeInt(u32, .little);
    const ref: Ref = @bitCast(raw);
    return entries[@backingInt(ref.id)].name;
}
