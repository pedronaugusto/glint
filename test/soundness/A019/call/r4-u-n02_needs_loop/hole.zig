// review 4: u/n02_needs_loop.zig
// held? init reads b on the second pass of a loop only (expected flagged)
const S = struct {
    a: u32,
    b: u32,
    fn init(self: *S, k: usize) u32 {
        var t: u32 = 0;
        var i: usize = 0;
        while (i < k) : (i += 1) {
            if (i > 0) t += self.b;
            self.a = 1;
        }
        return t;
    }
};
pub fn main(k: usize) u32 {
    var s: S = undefined;
    s.a = 0;
    return s.init(k);
}
