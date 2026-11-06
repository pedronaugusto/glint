//! A library's declared roles: what the types and functions of a package mean, as the package
//! states them in its module roots' `lint_rules` (PackageRules), read into a pack's own roles.
//! File bytes, file names, spellings and library revisions do not enter.

/// A package by its identity: the name and fingerprint its `build.zig.zon` gives.
pub const Package = struct { name: []const u8, fingerprint: u64 };

/// `R` is the pack's own enum of roles: a role the package declares is the one of `R` its enum
/// literal names (`.role = .secret`), and a role `R` does not name is another pack's. A library
/// is plain data that must outlive the run it is used in, because the resolver remembers it by
/// its package.
pub fn Library(comptime R: type) type {
    return struct {
        pub const Role = R;
        /// The package whose roots declare the roles (aegis's): its files are those the caller
        /// states to be of it, wherever they are fetched (a fork's copy under bay's cache is the
        /// package), and only they. A copy vendored into another package's tree is that package's.
        package: Package,
    };
}
