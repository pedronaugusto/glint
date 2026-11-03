// warp-fast: an enum that names no tag is an id: moved on its own value in two functions and
// switched on, it picks what it names, not a state.
const Id = enum(u32) { _ };
pub const Cursor = struct {
    at: Id = @fromBackingInt(@intCast(0)),
    pub fn next(c: *Cursor) void {
        switch (c.at) {
            @as(Id, @fromBackingInt(@intCast(0))) => c.at = @fromBackingInt(@intCast(1)),
            else => {},
        }
    }
    pub fn skip(c: *Cursor) void {
        if (c.at == @as(Id, @fromBackingInt(@intCast(1)))) c.at = @fromBackingInt(@intCast(2));
    }
    pub fn report(c: *const Cursor) u8 {
        return switch (c.at) {
            @as(Id, @fromBackingInt(@intCast(0))) => 0,
            @as(Id, @fromBackingInt(@intCast(1))) => 1,
            else => 2,
        };
    }
};
