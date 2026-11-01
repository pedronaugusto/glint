// c1: a program's other file, read first: it spends this file's fact budget inside the answers
// the run keeps for every file (std's reader, resolved once)
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const n = try r.takeByte();
    var list: std.ArrayList(u8) = .empty;
    _ = &list;
    return table[n];
}
