// P009: the address of the local an extern call wrote given to a part of the struct returned.
extern fn create(out: *?*anyopaque) c_int;
const Held = struct { handle: *const ?*anyopaque };
pub fn f() Held {
    var handle: ?*anyopaque = null;
    _ = create(&handle);
    var out: Held = undefined;
    out.handle = &handle;
    return out;
}
