//! Zig std front-end model and code rules. Runtime closure: aegis and std.
/// An owned, immutable project constructed from explicit source inputs.
pub const Project = @import("Project.zig");
/// Verifies CLI completion independently of finding acceptance.
pub const Completion = @import("Completion.zig");
/// Stable diagnostic selection IDs.
pub const Rule = @import("Rule.zig").Rule;
/// Explicit rule selection and work budgets.
pub const Config = @import("Rule.zig").Config;
/// Owned diagnostics and coverage, rendered as text, JSON or SARIF.
pub const Report = @import("Report.zig");
/// Runs the selected code checks over one frozen project.
pub const run = @import("Runner.zig").run;
test {
    _ = @import("File.zig");
    _ = @import("Model.zig");
    _ = Project;
    _ = Completion;
    _ = @import("Rule.zig");
    _ = @import("Suppression.zig");
    _ = @import("Runner.zig");
    _ = @import("Facts.zig");
}

/// Public compiled-rule context, shared with built-ins.
pub const RuleContext = @import("RuleContext.zig");
/// Compiled project rule descriptor.
pub const ProjectRule = RuleContext.Rule;
/// Rule metadata for custom IDs, versions and bug/policy classes.
pub const RuleDefinition = @import("Rule.zig").Definition;
/// Runs compiled project rules and per-source configuration on the same model.
pub const runConfigured = @import("Runner.zig").runConfigured;
/// Explicit source overrides: callers select these using their own path dialect.
pub const FileConfig = @import("Runner.zig").FileConfig;

/// Imports, resolved references/calls and source contexts for architecture consumers.
pub const Projection = @import("Projection.zig");

/// Parses a built-in or registered compiled-rule selection without numeric aliases.
pub const parseRule = @import("Rule.zig").parseConfigured;

/// Immutable declaration identity and conservative value shape exposed to project rules.
pub const Symbol = @import("Facts.zig").Decl;
pub const Value = @import("Facts.zig").Value;
pub const Unknown = @import("Facts.zig").Unknown;
pub const Declaration = @import("Model.zig").Declaration;
pub const Scope = @import("Model.zig").Scope;
pub const Reference = @import("Model.zig").Reference;
pub const RuleGroup = @import("Rule.zig").Group;

/// Optional configurable obligations for the published aegis contract.
pub const AegisPack = @import("AegisPack.zig");

/// Fast std-tokenizer imports, spellings and test liveness without parsing or lowering.
pub const Token = @import("glint_token");
