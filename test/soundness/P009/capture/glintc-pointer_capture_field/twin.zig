// P009: a pointer capture of the local's payload stores a value made from what it held, no
// frame address (shakedown programs/calls.zig's translateOperation).
const Op = union(enum) { read: struct { buffer: []u8 }, none };
fn translate(buffer: []u8) []u8 {
    return buffer[1..];
}
pub fn f(operation: Op) Op {
    var op = operation;
    switch (op) {
        .read => |*r| r.buffer = translate(r.buffer),
        .none => {},
    }
    return op;
}
