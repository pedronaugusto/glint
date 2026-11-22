// P007: a local taken from an array alias's element, then incremented: integer arithmetic.
const Range = [2]u21;
pub fn f(ranges: []const Range) u32 {
    var n: u32 = 0;
    for (ranges) |r| {
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) n += 1;
    }
    return n;
}
