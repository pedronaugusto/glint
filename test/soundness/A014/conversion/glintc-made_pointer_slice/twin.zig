// matrix: a slice of a local pointer made from an integer, in a generic whose binding does not resolve, returned
const State = struct { window: [8]u8 = undefined, bytes: []u8 = &.{} };
fn moved(slice: anytype, old: *const State, fresh: *State) @TypeOf(slice) {
    if (slice.len == 0) return slice;
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(old);
    const pointer: @TypeOf(slice.ptr) = @ptrFromInt(@intFromPtr(fresh) + offset);
    return pointer[0..slice.len];
}
pub fn copy(old: *const State, fresh: *State, other: anytype) void {
    fresh.bytes = moved(old.bytes, old, fresh);
    _ = moved(other, old, fresh);
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn copyBytes(old: *const State, fresh: *State, other: []u8) void {
    copy(old, fresh, other);
}
