// glint-b: a method of an `anytype` store opens a directory the binding's store does not hold:
// what the generic makes there is acquired, and never closed.
const std = @import("std");
const Store = struct {
    common_dir: std.Io.Dir,
    pub fn gitDir(store: *const Store, io: std.Io) !std.Io.Dir {
        return store.common_dir.openDir(io, ".git", .{});
    }
};
pub fn separate(store: anytype, io: std.Io) !bool {
    const git = try store.gitDir(io);
    return git.handle != store.common_dir.handle;
}
pub fn f(store: *const Store, io: std.Io) !bool {
    return separate(store, io);
}
