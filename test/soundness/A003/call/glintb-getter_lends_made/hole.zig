// glint-b: a getter of an `anytype` store returns a field of a record it makes there from a
// directory it opens: no field of what it is given, so what the generic makes is acquired, and
// never closed.
const std = @import("std");
const Held = struct { dir: std.Io.Dir };
const Store = struct {
    common_dir: std.Io.Dir,
    pub fn gitDir(store: *const Store, io: std.Io) !std.Io.Dir {
        const held: Held = .{ .dir = try store.common_dir.openDir(io, ".git", .{}) };
        return held.dir;
    }
};
pub fn separate(store: anytype, io: std.Io) !bool {
    const git = try store.gitDir(io);
    return git.handle != store.common_dir.handle;
}
pub fn f(store: *const Store, io: std.Io) !bool {
    return separate(store, io);
}
