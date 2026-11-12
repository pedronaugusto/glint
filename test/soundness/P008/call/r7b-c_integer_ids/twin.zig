// twin: one identifying parameter, the other a count
pub fn link(parent_id: c_uint, count: c_uint) c_uint {
    return parent_id +% count;
}
