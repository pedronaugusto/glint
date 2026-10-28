//! Owned diagnostics and independent coverage. Rendering cannot alter model results.
const std = @import("std");
const release = @import("release");
const Project = @import("Project.zig");
const rules = @import("Rule.zig");
const Report = @This();

arena: std.heap.ArenaAllocator,
snapshot: u64,
diagnostics: []const Diagnostic,
coverage: []const Coverage,
suppressed: usize,
/// How many suppressions matched no finding.
stale_suppressions: usize,
/// Each suppression that matched no finding, at its comment.
stale: []const Stale = &.{},
/// Each aegis escape that covered a finding, with the findings it covered: what the review reads.
escapes: []const Escape = &.{},
/// Each comment that reads as a suppression or an escape and is not one; any makes the run
/// incomplete.
malformed: []const Malformed = &.{},
complete: bool,
/// Assertion metrics, when the configuration asks for them (`Config.metrics`).
metrics: ?Metrics = null,

/// Per selected file, the functions it declares and the assertion calls in them, each counted
/// by the declaration its callee resolves to. A report, never a proof or a gate.
pub const Metrics = struct {
    files: []const File,
    total: Counts,

    pub const File = struct { file: Project.FileId, counts: Counts };
    /// An assertion call by the declaration it resolves to.
    pub const Kind = enum {
        /// `std.debug.assert`, checked in Debug and ReleaseSafe only.
        std_assert,
        invariant,
        pre,
        post,
        never,
        debug,
        debug_check,

        /// The declaration as a program names it.
        pub fn label(self: Kind) []const u8 {
            return switch (self) {
                .std_assert => "std.debug.assert",
                .invariant => "aegis.assert.invariant",
                .pre => "aegis.assert.pre",
                .post => "aegis.assert.post",
                .never => "aegis.assert.never",
                .debug => "aegis.assert.debug",
                .debug_check => "aegis.assert.debugCheck",
            };
        }
    };
    /// One file's counts, or a sum of them.
    pub const Counts = struct {
        /// Functions with a body; test blocks are not functions.
        functions: u32 = 0,
        /// Functions whose own body makes at least one assertion call.
        asserted: u32 = 0,
        assertions: [std.meta.tags(Kind).len]u32 = @splat(0),
        /// Calls spelled `assert`, `invariant`, `pre`, `post`, `never` or `debugCheck` whose
        /// callee does not resolve: assertions the counts above may miss.
        unresolved: u32 = 0,

        pub fn add(self: *Counts, other: Counts) void {
            self.functions += other.functions;
            self.asserted += other.asserted;
            for (&self.assertions, other.assertions) |*sum, n| sum.* += n;
            self.unresolved += other.unresolved;
        }
        pub fn total(self: Counts) u32 {
            var sum: u32 = 0;
            for (self.assertions) |n| sum += n;
            return sum;
        }
    };
};

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
    /// The finding's deterministic fix, when it has one: edits of its file's bytes.
    fix: []const Edit = &.{},
};
/// One replacement of a file's bytes from `start` to `end` with `text`.
pub const Edit = struct {
    start: u32,
    end: u32,
    text: []const u8,
    /// A bracket one finding opens or closes around its own operand: two findings' brackets
    /// at one offset nest (`((a - b) >> 31) ^ 1`), so each is made, where an edit findings
    /// share otherwise is made once.
    nests: bool = false,
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
/// A suppression that suppressed nothing: the rule it names (`aegis` for an escape) and its
/// comment's site.
pub const Stale = struct { name: []const u8, span: Span };
/// An aegis escape (`// aegis: <reason>: <why>`) at its comment, and the pack's findings on its
/// line that it covered.
pub const Escape = struct { span: Span, reason: []const u8, why: []const u8, covered: []const Covered };
pub const Covered = struct { name: []const u8, span: Span };
pub const Malformed = struct { why: []const u8, span: Span };
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
            for (self.stale) |stale| try writer.print("suppression: {s}:{d}:{d}: {s} suppresses nothing\n", .{ project.inputs[stale.span.file.raw()].name, stale.span.line, stale.span.column, stale.name }); // safe: enum identities index their owning frozen tables without narrowing.
            for (self.malformed) |entry| try writer.print("suppression: {s}:{d}:{d}: malformed: {s}\n", .{ project.inputs[entry.span.file.raw()].name, entry.span.line, entry.span.column, entry.why }); // safe: enum identities index their owning frozen tables without narrowing.
            for (self.escapes) |escape| {
                try writer.print("escape: {s}:{d}:{d}: {s}: {s} (", .{ project.inputs[escape.span.file.raw()].name, escape.span.line, escape.span.column, escape.reason, escape.why }); // safe: enum identities index their owning frozen tables without narrowing.
                for (escape.covered, 0..) |covered, i| try writer.print("{s}{s} at {d}:{d}", .{ if (i == 0) "" else ", ", covered.name, covered.span.line, covered.span.column });
                try writer.writeAll(")\n");
            }
            if (self.metrics) |metrics| try textMetrics(writer, metrics);
        },
        .json => {
            try writer.print("{{\"version\":1,\"analysis_complete\":{s},\"suppressed\":{d},\"stale_suppressions\":{d},\"stale\":[", .{ if (self.complete) "true" else "false", self.suppressed, self.stale.len });
            for (self.stale, 0..) |stale, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.inputs[stale.span.file.raw()].name, .rule = stale.name, .line = stale.span.line, .column = stale.span.column }, .{}, writer); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeAll("],\"malformed\":[");
            for (self.malformed, 0..) |entry, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.inputs[entry.span.file.raw()].name, .line = entry.span.line, .column = entry.span.column, .why = entry.why }, .{}, writer); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeAll("],\"escapes\":[");
            for (self.escapes, 0..) |escape, i| {
                if (i != 0) try writer.writeByte(',');
                try jsonEscape(writer, project, escape);
            }
            try writer.writeAll("],\"diagnostics\":[");
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try jsonDiagnostic(writer, project, d); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeAll("],\"coverage\":[");
            for (self.coverage, 0..) |c, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.inputs[c.file.raw()].name, .rule = if (c.rule == null) @as(?[]const u8, null) else c.rule_name, .start = c.start, .reason = c.reason, .detail = c.detail }, .{}, writer); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeByte(']');
            if (self.metrics) |metrics| {
                try writer.writeAll(",\"metrics\":{");
                try jsonCounts(writer, metrics.total);
                try writer.writeAll(",\"files\":[");
                for (metrics.files, 0..) |entry, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writer.writeAll("{\"source\":");
                    try std.json.Stringify.value(project.inputs[entry.file.raw()].name, .{}, writer); // safe: enum identities index their owning frozen tables without narrowing.
                    try writer.writeByte(',');
                    try jsonCounts(writer, entry.counts);
                    try writer.writeByte('}');
                }
                try writer.writeAll("]}");
            }
            try writer.writeAll("}\n");
        },
        .sarif => {
            try writer.writeAll("{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"glint\",\"version\":\"" ++ release.version ++ "\"}},\"results\":[");
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try sarifDiagnostic(writer, project, d);
            }
            try writer.print("],\"properties\":{{\"analysisComplete\":{s},\"suppressed\":{d},\"staleSuppressions\":{d},\"stale\":[", .{ if (self.complete) "true" else "false", self.suppressed, self.stale.len });
            for (self.stale, 0..) |stale, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .file = stale.span.file.raw(), .rule = stale.name, .start = stale.span.start, .line = stale.span.line, .column = stale.span.column }, .{}, writer);
            }
            try writer.writeAll("],\"coverage\":");
            try writer.writeByte('[');
            for (self.coverage, 0..) |c, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .file = c.file.raw(), .rule = if (c.rule == null) @as(?[]const u8, null) else c.rule_name, .start = c.start, .reason = c.reason, .detail = c.detail }, .{}, writer); // safe: explicit nullable metadata representation, without narrowing.
            }
            try writer.writeByte(']');
            try writer.writeAll("}}]}\n");
        },
    }
}

fn textMetrics(writer: *std.Io.Writer, metrics: Metrics) std.Io.Writer.Error!void {
    const t = metrics.total;
    try writer.print("metrics: {d} files, {d} functions, {d} with an assertion, {d} assertions", .{ metrics.files.len, t.functions, t.asserted, t.total() });
    var first = true;
    for (std.meta.tags(Metrics.Kind), t.assertions) |kind, n| if (n != 0) {
        try writer.print("{s}{s} {d}", .{ if (first) " (" else ", ", kind.label(), n });
        first = false;
    };
    if (!first) try writer.writeByte(')');
    if (t.unresolved != 0) try writer.print(", {d} assertion-like calls unresolved", .{t.unresolved});
    try writer.writeByte('\n');
}

fn jsonCounts(writer: *std.Io.Writer, counts: Metrics.Counts) std.Io.Writer.Error!void {
    try writer.print("\"functions\":{d},\"asserted\":{d},\"unresolved\":{d},\"assertions\":{{", .{ counts.functions, counts.asserted, counts.unresolved });
    for (std.meta.tags(Metrics.Kind), counts.assertions, 0..) |kind, n, i| try writer.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", kind.label(), n });
    try writer.writeByte('}');
}

fn jsonEscape(writer: *std.Io.Writer, project: *const Project, escape: Escape) std.Io.Writer.Error!void {
    var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stream.beginObject();
    try stream.objectField("source");
    try stream.write(project.inputs[escape.span.file.raw()].name); // safe: the span belongs to this report's verified project.
    try stream.objectField("span");
    try stream.write(wireSpan(escape.span));
    try stream.objectField("reason");
    try stream.write(escape.reason);
    try stream.objectField("why");
    try stream.write(escape.why);
    try stream.objectField("covered");
    try stream.beginArray();
    for (escape.covered) |covered| try stream.write(.{ .rule = covered.name, .span = wireSpan(covered.span) });
    try stream.endArray();
    try stream.endObject();
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
    try stream.write(.{ .ruleVersion = d.rule_version, .class = d.class, .policyLevel = d.level, .bugClass = d.bug_class });
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
