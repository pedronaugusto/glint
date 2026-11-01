// matrix: pointers into the frame unrolled by an inline for and stored through the caller's pointer
pub fn f(out: **u32) void {
    var x: u32 = 1;
    x += 1;
    inline for (.{&x}) |p| out.* = p;
}
