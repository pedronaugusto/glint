// A015: a tagged union with a field written without a type (void): no handle held.
const aegis = @import("aegis");
pub const Sink = union(enum) { byte: u8, none };
