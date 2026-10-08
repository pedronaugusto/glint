//! Owned diagnostics and independent coverage. Rendering cannot alter model results.
const std = @import("std");
const Project = @import("Project.zig");
const rules = @import("Rule.zig");
const Report = @This();

arena: std.heap.ArenaAllocator,
snapshot: u64,
diagnostics: []const Diagnostic,
coverage: []const Coverage,
suppressed: usize,
stale_suppressions: usize,
complete: bool,

pub const Span = struct { file: Project.FileId, start: u32, end: u32, line: u32, column: u32 };
pub const Diagnostic = struct {
    rule: rules.Rule,
    name: []const u8 = "",
    rule_version: u32 = 1,
    class: enum { correctness, zig_style, family_policy },
    level: rules.Config.Level = .report,
    severity: enum { @"error", warning, note },
    span: Span,
    message: []const u8,
    bug_class: []const u8,
    related: []const Span = &.{},
};
pub const Coverage = struct {
    file: Project.FileId,
    rule: ?rules.Rule = null,
    rule_name: []const u8 = "",
    start: u32 = 0,
    reason: Reason,
    detail: []const u8 = "",
    pub const Reason = enum { parsed, invalid_syntax, invalid_lowering, budget_exhausted, unresolved, unsupported };
};
pub const Format = enum { text, json, sarif };
pub const WriteError = std.Io.Writer.Error || error{InvalidProject};

pub fn deinit(self: *Report) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn write(self: *const Report, writer: *std.Io.Writer, project: *const Project, format: Format) WriteError!void {
    if (self.snapshot != project.identity) return error.InvalidProject;
    switch (format) {
        .text => {
            for (self.diagnostics) |diagnostic| try writer.print("{s}: {s}:{d}:{d}: {s}\n", .{
                diagnostic.name,      project.inputs[diagnostic.span.file.raw()].name, // safe: enum identities index their owning frozen tables without narrowing.
                diagnostic.span.line, diagnostic.span.column,
                diagnostic.message,
            });
            for (self.coverage) |coverage| if (coverage.reason != .parsed) {
                try writer.print("coverage: {s}: {s}: {s}\n", .{ project.inputs[coverage.file.raw()].name, @tagName(coverage.reason), coverage.detail }); // safe: enum identities index their owning frozen tables without narrowing.
            };
            if (self.stale_suppressions != 0) try writer.print("suppression: {d} stale site records\n", .{self.stale_suppressions});
        },
        .json => {
            try writer.print("{{\"version\":1,\"analysis_complete\":{s},\"suppressed\":{d},\"stale_suppressions\":{d},\"diagnostics\":[", .{ if (self.complete) "true" else "false", self.suppressed, self.stale_suppressions });
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try jsonDiagnostic(writer, project, d); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeAll("],\"coverage\":[");
            for (self.coverage, 0..) |c, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.inputs[c.file.raw()].name, .rule = if (c.rule == null) @as(?[]const u8, null) else c.rule_name, .start = c.start, .reason = c.reason, .detail = c.detail }, .{}, writer); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeAll("]}\n");
        },
        .sarif => {
            try writer.writeAll("{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"glint\",\"version\":\"0.1.0\"}},\"results\":[");
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try sarifDiagnostic(writer, project, d);
            }
            try writer.print("],\"properties\":{{\"analysisComplete\":{s},\"suppressed\":{d},\"staleSuppressions\":{d},\"coverage\":", .{ if (self.complete) "true" else "false", self.suppressed, self.stale_suppressions });
            try writer.writeByte('[');
            for (self.coverage, 0..) |c, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .file = c.file.raw(), .rule = if (c.rule == null) @as(?[]const u8, null) else c.rule_name, .start = c.start, .reason = c.reason, .detail = c.detail }, .{}, writer);
            }
            try writer.writeByte(']');
            try writer.writeAll("}}]}\n");
        },
    }
}

fn jsonDiagnostic(writer: *std.Io.Writer, project: *const Project, d: Diagnostic) std.Io.Writer.Error!void {
    var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
    const record = .{ .rule = d.name, .rule_version = d.rule_version, .class = d.class, .severity = d.severity, .source = project.inputs[d.span.file.raw()].name, .span = wireSpan(d.span), .level = d.level, .message = d.message, .bug_class = d.bug_class }; // safe: the span belongs to this report's verified project.
    try stream.beginObject();
    inline for (@typeInfo(@TypeOf(record)).@"struct".field_names) |name| {
        try stream.objectField(name);
        try stream.write(@field(record, name));
    }
    try stream.objectField("related");
    try relatedLocations(&stream, project, d.related, false);
    try stream.endObject();
}

fn writeUri(stream: *std.json.Stringify, label: []const u8) std.Io.Writer.Error!void {
    try stream.beginWriteRaw();
    try stream.writer.writeByte('"');
    try (std.Uri.Component{ .raw = label }).formatPath(stream.writer);
    try stream.writer.writeByte('"');
    stream.endWriteRaw();
}

fn physicalLocation(stream: *std.json.Stringify, project: *const Project, span: Span) std.Io.Writer.Error!void {
    try stream.beginObject();
    try stream.objectField("artifactLocation");
    try stream.beginObject();
    try stream.objectField("uri");
    try writeUri(stream, project.inputs[span.file.raw()].name); // safe: the span belongs to this report's verified project.
    try stream.endObject();
    try stream.objectField("region");
    // Byte offsets stay precise for non-ASCII and invalid UTF-8 source. A byte
    // column is not mislabeled as SARIF's default UTF-16 column.
    try stream.write(.{ .startLine = span.line, .byteOffset = span.start, .byteLength = span.end - span.start });
    try stream.endObject();
}

fn relatedLocations(stream: *std.json.Stringify, project: *const Project, spans: []const Span, sarif: bool) std.Io.Writer.Error!void {
    try stream.beginArray();
    for (spans, 0..) |span, index| {
        if (sarif) {
            try stream.beginObject();
            try stream.objectField("id");
            try stream.write(index + 1);
            try stream.objectField("physicalLocation");
            try physicalLocation(stream, project, span);
            try stream.endObject();
        } else try stream.write(.{ .source = project.inputs[span.file.raw()].name, .span = wireSpan(span) }); // safe: related spans index this report's verified project.
    }
    try stream.endArray();
}

fn sarifDiagnostic(writer: *std.Io.Writer, project: *const Project, d: Diagnostic) std.Io.Writer.Error!void {
    var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stream.beginObject();
    try stream.objectField("ruleId");
    try stream.write(d.name);
    try stream.objectField("level");
    try stream.write(@tagName(d.severity));
    try stream.objectField("message");
    try stream.write(.{ .text = d.message });
    try stream.objectField("locations");
    try stream.beginArray();
    try stream.beginObject();
    try stream.objectField("physicalLocation");
    try physicalLocation(&stream, project, d.span);
    try stream.endObject();
    try stream.endArray();
    try stream.objectField("relatedLocations");
    try relatedLocations(&stream, project, d.related, true);
    try stream.objectField("properties");
    try stream.write(.{ .ruleVersion = d.rule_version, .class = d.class, .bugClass = d.bug_class });
    try stream.endObject();
}

fn wireSpan(span: Span) struct { file: u32, start: u32, end: u32, line: u32, column: u32 } {
    return .{ .file = span.file.raw(), .start = span.start, .end = span.end, .line = span.line, .column = span.column };
}
/// Findings selected to gate. Completion is checked independently, before acceptance.
pub fn gateFindings(self: *const Report) usize {
    var count: usize = 0;
    for (self.diagnostics) |diagnostic| if (diagnostic.level == .gate) {
        count += 1;
    };
    return count;
}
