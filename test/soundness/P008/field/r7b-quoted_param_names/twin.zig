// twin: quoted identifying parameters of two integer types
pub fn link(@"parent_id": u32, @"child_id": u64) u64 {
    return @"parent_id" +% @"child_id";
}
