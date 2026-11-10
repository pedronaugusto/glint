// glint-c: a function's greatest return is read from its own body, however deep in a chain of calls its first reader sits: a product of a width a switch on input picks among the function's literals fits
const std = @import("std");
const Kind = enum { short, long };
fn w0(kind: Kind) usize {
    return switch (kind) {
        .short => 20,
        .long => 32,
    };
}
fn w1(kind: Kind) usize {
    return w0(kind);
}
fn w2(kind: Kind) usize {
    return w1(kind);
}
fn w3(kind: Kind) usize {
    return w2(kind);
}
fn w4(kind: Kind) usize {
    return w3(kind);
}
fn w5(kind: Kind) usize {
    return w4(kind);
}
fn w6(kind: Kind) usize {
    return w5(kind);
}
fn w7(kind: Kind) usize {
    return w6(kind);
}
fn w8(kind: Kind) usize {
    return w7(kind);
}
fn w9(kind: Kind) usize {
    return w8(kind);
}
fn w10(kind: Kind) usize {
    return w9(kind);
}
pub fn first(r: *std.Io.Reader) !usize {
    const a = try r.takeInt(u8, .big);
    return @as(usize, a) + @as(usize, @as(usize, @as(usize, w10(.short))));
}
pub fn f(r: *std.Io.Reader) !usize {
    const width: usize = switch (try r.takeInt(u8, .big)) {
        1 => w10(.short),
        2 => w10(.long),
        else => return error.Invalid,
    };
    return 2 * width;
}
