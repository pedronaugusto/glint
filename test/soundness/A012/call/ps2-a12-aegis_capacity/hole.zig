// aegis's SecretBytes allocates the capacity it is given, a number a peer chose: aegis is read as
// the limit itself, so the call is no size site
const std = @import("std");
const aegis = @import("aegis");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !aegis.SecretBytes {
    const n = try r.takeInt(u32, .little);
    return aegis.SecretBytes.init(gpa, n);
}
