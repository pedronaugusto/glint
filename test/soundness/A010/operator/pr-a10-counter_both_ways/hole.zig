// precision A010 operator: a write between the steps sets the depth to the peer's number, which the next step up overflows
const std = @import("std");
pub fn f(r: *std.Io.Reader) !bool {
    const text = try r.take(try r.takeInt(u16, .little));
    const reset = try r.takeInt(u64, .little);
    var depth: u64 = 0;
    for (text) |c| switch (c) {
        '{' => depth += 1,
        '}' => {
            if (depth == 0) return error.Unbalanced;
            depth -= 1;
        },
        else => depth = reset,
    };
    return depth == 0;
}
