// P007: C variadic arguments read as whatever type the program names (review 8, m3).
pub fn sum(n: c_int, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var total: c_int = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1) total += @cVaArg(&ap, c_int);
    return total;
}
