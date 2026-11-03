// pre-sweep-2 A008: a generic copies what its pointer points at into a local typed
// `std.meta.Child([1]T)`; left to the bindings, but with the call's binding (T = dep.Wallet, which
// holds an Ed25519.SecretKey) the type still does not resolve, and the copy is never reported.
const std = @import("std");
const dep = @import("dep.zig");
fn first(comptime T: type, w: *const T) u8 {
    const copy: std.meta.Child([1]T) = w.*;
    return copy.label;
}
pub fn run(w: *const dep.Wallet) u8 {
    return first(dep.Wallet, w);
}
