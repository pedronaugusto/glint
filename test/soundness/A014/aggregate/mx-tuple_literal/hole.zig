// matrix: a pointer into the frame put into an array literal, returned
pub fn f() [1]*u32 {
    var x: u32 = 1;
    x += 1;
    return .{&x};
}
