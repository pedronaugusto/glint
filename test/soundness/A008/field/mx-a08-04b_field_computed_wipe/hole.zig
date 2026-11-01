// matrix A008: std's secureZero named by @field with a computed name: a hand wipe.
const std = @import("std");
pub fn wipe(buffer: []u8) void {
    @field(std.crypto, "secure" ++ "Zero")(u8, buffer);
}
