//! Test support: what reaches it decides whether its public declarations are a consumer's.
const Kind = enum { quick, slow };
pub const Tool = struct { kind: Kind };
