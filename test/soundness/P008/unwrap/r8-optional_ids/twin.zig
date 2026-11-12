// P008: optional ids of distinct types keep apart.
pub const Parent = enum(u32) { _ };
pub const Child = enum(u32) { _ };
pub fn maybe(parent_id: ?Parent, child_id: ?Child) void {
    _ = parent_id;
    _ = child_id;
}
