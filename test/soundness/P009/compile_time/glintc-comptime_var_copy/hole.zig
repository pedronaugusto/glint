// P009: a const copied from a runtime var holds the frame's bytes; its address returned dangles.
pub fn separators() []const u8 {
    var buffer: [3]u8 = .{ 'a', '/', 'b' };
    buffer[1] = '\\';
    const final = buffer;
    return &final;
}
