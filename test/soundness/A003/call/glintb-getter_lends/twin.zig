// glint-b: a method of an `anytype` store returns a directory its store holds, by value (relic's
// `store.gitDir()`): a loan of the store's own, no acquisition, so the generic owes no close.
const std = @import("std");
const Store = struct {
    git_dir: std.Io.Dir,
    common_dir: std.Io.Dir,
    pub fn gitDir(store: *const Store) std.Io.Dir {
        return store.git_dir;
    }
    pub fn commonDir(store: *const Store) std.Io.Dir {
        return store.common_dir;
    }
};
pub fn separate(store: anytype) bool {
    return store.gitDir().handle != store.commonDir().handle;
}
pub fn f(store: *const Store) bool {
    return separate(store);
}
