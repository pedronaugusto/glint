// matrix A007: the same cell held by aegis's Atomic.
const aegis = @import("aegis");
pub fn Flag(comptime T: type) type {
    return struct {
        state: aegis.Atomic(T),
        pub fn set(f: *@This(), value: T) T {
            return f.state.swap(value, .acq_rel);
        }
    };
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
const State = enum(u8) { off, on };
pub fn setFlag(f: *Flag(State)) State {
    return f.set(.on);
}
