// matrix: a pointer capture into a local optional's payload, returned
pub fn f(n: u32) ?*u32 {
    var maybe: ?u32 = n;
    if (maybe) |*v| return v;
    return null;
}
