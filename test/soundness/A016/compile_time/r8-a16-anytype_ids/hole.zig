// warp-fast: two `anytype` ids, each whatever a caller gives: two u32 among them.
pub fn link(parent_id: anytype, child_id: anytype) u64 {
    return @as(u64, parent_id) + @as(u64, child_id);
}
