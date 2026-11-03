const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader) !u64 {
    var held: aegis.bounded.Array(u64, 4) = .init;
    var v = try r.takeInt(u64, .little);
    try held.append(&v);
    var out: u64 = 0;
    try held.pop(&out);
    return out *| 3;
}
