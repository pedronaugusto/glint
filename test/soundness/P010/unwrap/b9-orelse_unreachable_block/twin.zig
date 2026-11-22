// P010: an optional unwrapped by `orelse` into a block that gives a value: no trap.
pub fn g(x: ?u32) u32 {
    return x orelse {
        return 0;
    };
}
