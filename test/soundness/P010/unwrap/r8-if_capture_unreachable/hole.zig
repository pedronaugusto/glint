// P010 (review 8, m13): an optional's capture with a trapping else is the same unwrap.
pub fn f(x: ?u8) u8 {
    return if (x) |v| v else unreachable;
}
