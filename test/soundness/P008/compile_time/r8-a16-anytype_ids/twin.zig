// warp-fast: one `anytype` id beside a count: nothing identifying meets it.
pub fn link(parent_id: anytype, count: u32) u64 {
    return @as(u64, parent_id) + count;
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn link32(parent_id: u32, count: u32) u64 {
    return link(parent_id, count);
}
