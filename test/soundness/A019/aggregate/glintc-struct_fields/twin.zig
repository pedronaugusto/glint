// A019 aggregate: every field of a struct is written before the struct is read whole
const P = struct { a: u32, b: u32 };
pub fn make(c: bool) P {
    var p: P = undefined;
    p.a = 1;
    p.b = if (c) 2 else 3;
    return p;
}
