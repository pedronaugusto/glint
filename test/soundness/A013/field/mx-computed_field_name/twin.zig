// matrix: @field with a name held in a constant reads the part a peer sent, refused by an error
const std = @import("std");
const Header = struct { kind: u8, flags: u8 };
const part = "kind";
pub fn f(r: *std.Io.Reader) !Header {
    const h: Header = .{ .kind = try r.takeByte(), .flags = 0 };
    if (@field(h, part) >= 4) return error.Bad;
    return h;
}
