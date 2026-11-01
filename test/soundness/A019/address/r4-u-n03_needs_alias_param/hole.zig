// review 4: u/n03_needs_alias_param.zig
// held? init(self, other) with other aliasing self reads other.b (expected flagged)
const S = struct {
    a: u32,
    b: u32,
    fn init(self: *S, other: *const S) void {
        self.a = other.b;
        self.b = 0;
    }
};
pub fn main() u32 {
    var s: S = undefined;
    s.init(&s);
    return s.a;
}
