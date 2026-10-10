//! A library's published contract: the roles its public declarations play, found through the
//! module a program imports it by. File bytes, file names and library revisions do not enter.

/// `R` is the pack's own enum of roles. A library is plain data that must outlive the run it is
/// used in, because the resolver remembers it by address.
pub fn Library(comptime R: type) type {
    return struct {
        pub const Role = R;
        /// Each module as programs import it: `@import("aegis")`, `@import("aegis.id")`.
        modules: []const Module,

        pub const Module = struct {
            /// The import spelling a program resolves to this module's root file.
            name: []const u8,
            members: []const Member,
        };
        /// A declaration the library publishes. `path` names it from the module root through
        /// public namespaces, such as `units.Bytes`, exactly as a program writes it.
        pub const Member = struct {
            path: []const u8,
            role: Role,
            /// A missing required member is drift, reported as coverage. An optional member is
            /// simply absent from older revisions of the library.
            required: bool = true,
        };
    };
}
