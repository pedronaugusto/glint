// P007: the same sum over a slice, whose items have their type.
pub fn sum(items: []const c_int) c_int {
    var total: c_int = 0;
    for (items) |item| total += item;
    return total;
}
