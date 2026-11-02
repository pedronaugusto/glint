// precision A010 operator: a depth stepped up and down once a pass over memory is at most the passes run, so its step up never overflows
const std = @import("std");
pub fn f(r: *std.Io.Reader) !bool {
    const text = try r.take(try r.takeInt(u16, .little));
    var depth: usize = 0;
    for (text) |c| switch (c) {
        '{' => depth += 1,
        '}' => {
            if (depth == 0) return error.Unbalanced;
            depth -= 1;
        },
        else => {},
    };
    return depth == 0;
}
