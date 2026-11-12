// A016: two identifying parameters of one integer type, their names written as quoted identifiers
pub fn link(@"parent_id": u32, @"child_id": u32) u32 {
    return @"parent_id" +% @"child_id";
}
