// P006 assignment: a type function's var, with no `comptime` of its own, holding a pointer type
// and given another: nothing disallowed is reached
pub fn F() type {
    var X = []const u8;
    X = []u8;
    return X;
}
