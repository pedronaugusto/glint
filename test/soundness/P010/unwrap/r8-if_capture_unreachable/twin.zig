// P010: an optional's capture with a value for null traps nowhere.
pub fn f(x: ?u8) u8 {
    return if (x) |v| v else 0;
}
