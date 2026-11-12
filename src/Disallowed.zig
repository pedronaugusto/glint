//! P006: declarations a project keeps out of its code (`Config.disallowed`), decided by what each
//! reference reaches (Governed.zig): a declaration named from a module as programs import it
//! (`std`'s `posix.fdatasync`), from a project input, or an external symbol, which every `extern`
//! declaration of it binds, so the program's own `extern fn fsync` is std's `c.fsync`. Each entry
//! names the packages that own its declaration: in their files it is the designed use. What a
//! package declares it replaces is its own rules' (`lint_rules`, Replaced.zig).
const std = @import("std");
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const Disallowed = @import("Rule.zig").Config.Disallowed;

pub fn check(self: *Context) Context.Error!void {
    if (!self.config.has(.P006)) return;
    const package = self.project.at(self.file).input.package;
    var targets: std.ArrayList(Governed.Target) = .empty;
    var indexes: std.ArrayList(usize) = .empty;
    for (self.config.disallowed, 0..) |entry, i| {
        if (owned(entry, package)) continue;
        try targets.append(self.allocator, .{ .source = entry.source, .declaration = entry.declaration, .production = entry.scope == .production });
        try indexes.append(self.allocator, i);
    }
    const configured = try Governed.resolve(self, .P006, targets.items, indexes.items);
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(self, configured, &sites, &unread);
    for (sites.items) |site| {
        const entry = self.config.disallowed[site.index];
        try self.atDefinition(.P006, site.token, try self.allocator.print("disallowed declaration: {s}; use {s}", .{ entry.reason, entry.replacement }), site.decl);
    }
    // A ban: a reference spelling a disallowed name that does not resolve cannot be shown to be another.
    const tree = &self.project.at(self.file).file.tree;
    for (unread.items) |missed| try self.at(.P006, tree.firstToken(missed.node), try self.allocator.print("a reference spelling a disallowed declaration does not resolve ({t}), so it cannot be shown to be another", .{missed.why}));
}

/// Whether `package` is one of the entry's owners. An unknown package owns nothing.
fn owned(entry: Disallowed, package: []const u8) bool {
    if (package.len == 0) return false;
    for (entry.owners) |owner| if (std.mem.eql(u8, owner, package)) return true;
    return false;
}
