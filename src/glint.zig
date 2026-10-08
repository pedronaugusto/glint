//! std-only Zig source model and selected code diagnostics.
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
