// glint-b: a getter of an `anytype` store returns a field of the record the store holds, through
// a local naming it: a loan of the store's own, no acquisition, so the generic owes no close.
const std = @import("std");
const Held = struct { dir: std.Io.Dir };
const Store = struct {
    held: Held,
    common_dir: std.Io.Dir,
    pub fn gitDir(store: *const Store) std.Io.Dir {
        const held = store.held;
        return held.dir;
    }
};
pub fn separate(store: anytype) bool {
    return store.gitDir().handle != store.common_dir.handle;
}
pub fn f(store: *const Store) bool {
    return separate(store);
}
