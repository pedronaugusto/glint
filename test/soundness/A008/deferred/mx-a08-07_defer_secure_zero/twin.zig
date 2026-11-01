// matrix A008: the same exit releasing aegis's SecretBytes, which wipes its whole capacity.
const std = @import("std");
const aegis = @import("aegis");
pub fn use(gpa: std.mem.Allocator, n: usize) !u8 {
    var bytes = try aegis.SecretBytes.init(gpa, n);
    defer bytes.deinit(gpa);
    return bytes.expose()[0];
}
