// P009: a pointer capture of the local's payload stores a local's address in it.
const Op = union(enum) { read: struct { buffer: []u8 }, none };
pub fn f(operation: Op) Op {
    var op = operation;
    var local: [4]u8 = undefined;
    switch (op) {
        .read => |*r| r.buffer = &local,
        .none => {},
    }
    return op;
}
