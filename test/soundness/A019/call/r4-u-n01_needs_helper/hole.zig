// review 4: u/n01_needs_helper.zig
// held? init writes a, then a helper reads b (expected flagged)
const S = struct {
    a: u32,
    b: u32,
    fn peek(self: *const S) u32 {
        return self.b;
    }
    fn init(self: *S) u32 {
        self.a = 1;
        return self.peek();
    }
};
pub fn main() u32 {
    var s: S = undefined;
    return s.init();
}
