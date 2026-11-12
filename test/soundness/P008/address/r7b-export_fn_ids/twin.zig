// twin: an exported function whose identifying parameters are of two integer types
export fn link(parent_id: u32, child_id: u64) u64 {
    return parent_id +% child_id;
}
