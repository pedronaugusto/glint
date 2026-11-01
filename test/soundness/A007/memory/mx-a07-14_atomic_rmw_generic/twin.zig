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
