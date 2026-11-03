// warp-fast: one `anytype` id beside a count: nothing identifying meets it.
pub fn link(parent_id: anytype, count: u32) u64 {
    return @as(u64, parent_id) + count;
}
