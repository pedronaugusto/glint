// review 4: u/u01c_init_literal_undefined_field.zig
// A019: init(*Self) writes the whole struct with a literal whose field is `undefined`; the caller
// then reads that field.
const S = struct {
    n: u32,
    buf: [8]u8,
    fn init(self: *S) void {
        self.* = .{ .n = 0, .buf = undefined };
    }
};
pub fn main() u8 {
    var s: S = undefined;
    s.init();
    return s.buf[3];
}
