// P009: a handle an extern call writes through the local's address: the outside function is
// handed no frame address but the local's own, so what it writes is its own (reactor and airlock
// NtCreate* handles, shakedown Region's reserved address).
extern fn create(out: *?*anyopaque) c_int;
pub fn f() ?*anyopaque {
    var handle: ?*anyopaque = null;
    _ = create(&handle);
    return handle;
}
