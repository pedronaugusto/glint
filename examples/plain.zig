//! A file the project example's rule passes: it exports nothing, and imports nothing a run
//! would have to map.
fn twice(x: u32) u32 {
    return x *% 2;
}

comptime {
    _ = twice;
}
