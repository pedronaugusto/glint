// A dependency's public generic that takes any value by value.
pub fn sizeOf(value: anytype) usize {
    return @sizeOf(@TypeOf(value));
}
