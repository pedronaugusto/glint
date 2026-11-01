// matrix: a pointer capture into the caller's optional's payload, returned
pub fn f(maybe: *?u32) ?*u32 {
    if (maybe.*) |*v| return v;
    return null;
}
