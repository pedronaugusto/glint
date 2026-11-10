// A009 conversion: an `extern` function answering a table's own id makes it in code the run
// does not read: the position it reaches may name no entry.
const std = @import("std");

const Entry = struct {
    name: u8,
    pub const Id = enum(u32) { _ };
};

extern fn pick(seed: u32) Entry.Id;

pub fn f(r: *std.Io.Reader, entries: []const Entry) !u8 {
    const id = pick(try r.takeInt(u32, .little));
    return entries[@backingInt(id)].name;
}
