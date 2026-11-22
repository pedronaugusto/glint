// P010: an optional unwrapped by `orelse` into a block that only traps, no reason written.
pub fn g(x: ?u32) u32 {
    return x orelse {
        unreachable;
    };
}
