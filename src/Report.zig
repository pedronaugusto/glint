//! Owned diagnostics and independent coverage. Rendering cannot alter model results.
const std = @import("std");
const Project = @import("Project.zig");
const rules = @import("Rule.zig");
const Report = @This();

arena: std.heap.ArenaAllocator,
diagnostics: []const Diagnostic,
coverage: []const Coverage,
suppressed: usize,
stale_suppressions: usize,
complete: bool,

pub const Span = struct { file: Project.FileId, start: u32, end: u32, line: u32, column: u32 };
pub const Diagnostic = struct {
    rule: rules.Rule,
    rule_version: u32 = 1,
    class: enum { correctness, hygiene, style, suspicious },
    severity: enum { @"error", warning, note },
    span: Span,
    message: []const u8,
    bug_class: []const u8,
    related: []const Span = &.{},
};
pub const Coverage = struct {
    file: Project.FileId,
    rule: ?rules.Rule = null,
    start: u32 = 0,
    reason: enum { parsed, invalid_syntax, invalid_lowering, budget_exhausted, unresolved, unsupported },
    detail: []const u8 = "",
};
pub const Format = enum { text, json, sarif };
pub const WriteError = std.Io.Writer.Error;

pub fn deinit(self: *Report) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn write(self: *const Report, writer: *std.Io.Writer, project: *const Project, format: Format) WriteError!void {
    switch (format) {
        .text => {
            for (self.diagnostics) |diagnostic| try writer.print("{s}: {s}:{d}:{d}: {s}\n", .{
                @tagName(diagnostic.rule), project.inputs[@backingInt(diagnostic.span.file)].name,
                diagnostic.span.line,      diagnostic.span.column,
                diagnostic.message,
            });
            for (self.coverage) |coverage| if (coverage.reason != .parsed) {
                try writer.print("coverage: {s}: {s}: {s}\n", .{ project.inputs[@backingInt(coverage.file)].name, @tagName(coverage.reason), coverage.detail });
            };
            if (self.stale_suppressions != 0) try writer.print("suppression: {d} stale site records\n", .{self.stale_suppressions});
        },
        .json => {
            try writer.print("{{\"version\":1,\"analysis_complete\":{s},\"suppressed\":{d},\"stale_suppressions\":{d},\"diagnostics\":[", .{ if (self.complete) "true" else "false", self.suppressed, self.stale_suppressions });
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .rule = @tagName(d.rule), .rule_version = d.rule_version, .class = d.class, .severity = d.severity, .source = project.inputs[@backingInt(d.span.file)].name, .span = d.span, .message = d.message, .bug_class = d.bug_class, .related = d.related }, .{}, writer);
            }
            try writer.writeAll("],\"coverage\":[");
            for (self.coverage, 0..) |c, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.inputs[@backingInt(c.file)].name, .rule = c.rule, .start = c.start, .reason = c.reason, .detail = c.detail }, .{}, writer);
            }
            try writer.writeAll("]}\n");
        },
        .sarif => {
            try writer.writeAll("{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"glint\",\"version\":\"0.1.0\"}},\"results\":[");
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .ruleId = @tagName(d.rule), .level = @tagName(d.severity), .message = .{ .text = d.message }, .locations = .{.{ .physicalLocation = .{
                    .artifactLocation = .{ .uri = project.inputs[@backingInt(d.span.file)].name },
                    .region = .{ .startLine = d.span.line, .startColumn = d.span.column, .byteOffset = d.span.start, .byteLength = d.span.end - d.span.start },
                } }}, .properties = .{ .ruleVersion = d.rule_version, .class = d.class, .bugClass = d.bug_class } }, .{}, writer);
            }
            try writer.print("],\"properties\":{{\"analysisComplete\":{s},\"suppressed\":{d},\"staleSuppressions\":{d},\"coverage\":", .{ if (self.complete) "true" else "false", self.suppressed, self.stale_suppressions });
            try std.json.Stringify.value(self.coverage, .{}, writer);
            try writer.writeAll("}}]}\n");
        },
    }
}
