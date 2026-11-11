//! glint's version, as its manifest (`build.zig.zon`) names it; build.zig refuses a build where
//! the two differ. A constant in source, not a build option: two glint packages of one version in
//! one build graph would make two options files of identical contents, which resolve to one
//! cached file in two modules, and Zig refuses that.
pub const version = "0.7.5";
