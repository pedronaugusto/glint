//! Owned findings, reports and run errors. Rendering cannot alter model results.
const std = @import("std");
const release = @import("version.zig");
const Project = @import("Project.zig");
const rules = @import("Rule.zig");
const Report = @This();

arena: std.heap.ArenaAllocator,
snapshot: u64,
diagnostics: []const Diagnostic,
/// What stops the run: a file glint cannot parse, an import no mapping names, a file whose
/// analysis ran out of its fact budget, a configuration that names nothing. Any makes the run
/// incomplete; there is no other kind of output beside the findings.
errors: []const RunError = &.{},
suppressed: usize,
/// How many suppressions matched no finding.
stale_suppressions: usize,
/// Each suppression that matched no finding, at its comment.
stale: []const Stale = &.{},
/// Each comment that reads as a suppression and is not one; any makes the run
/// incomplete.
malformed: []const Malformed = &.{},
complete: bool,
/// Assertion metrics, when the configuration asks for them (`Config.metrics`).
metrics: ?Metrics = null,
/// Each seam the configuration declares (`Config.seams`), with its sites per rule.
seams: []const SeamCount = &.{},
/// Each test input entry (`Config.test_inputs`), with how many files it holds.
test_inputs: []const TestInputCount = &.{},

/// A seam, where it is and why, the sites it held per rule, and whether it is stale: its rules
/// all ran and it held none.
pub const SeamCount = struct { where: []const u8, reason: []const u8, rules: []const RuleSites, stale: bool };
pub const RuleSites = struct { name: []const u8, sites: usize };
/// A test input entry and the files it holds; one holding none is stale.
pub const TestInputCount = struct { pattern: []const u8, files: usize };

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
        /// A declaration a package names in its place: a `.with` of a `lint_rules` entry that
        /// replaces `std.debug.assert`.
        replacement,

        /// What the count is of, as a report names it.
        pub fn label(self: Kind) []const u8 {
            return switch (self) {
                .std_assert => "std.debug.assert",
                .replacement => "its replacements",
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

        pub fn add(self: *Counts, other: Counts) void {
            self.functions += other.functions;
            self.asserted += other.asserted;
            for (&self.assertions, other.assertions) |*sum, n| sum.* += n;
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
/// A run error, and the file it is of where it is one file's.
pub const RunError = struct { file: ?Project.FileId = null, why: []const u8 };
/// A suppression that suppressed nothing: a rule it names that ran, and its comment's site.
pub const Stale = struct { name: []const u8, span: Span };
/// A comment or declaration glint cannot read: a suppression, or a part of a package's
/// `lint_rules`, each told apart in the report.
pub const Malformed = struct { why: []const u8, span: Span, of: enum { suppression, lint_rules } = .suppression };
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
                diagnostic.name,      project.at(diagnostic.span.file).input.name,
                diagnostic.span.line, diagnostic.span.column,
                diagnostic.message,
            });
            for (self.errors) |run_error| if (run_error.file) |file| {
                try writer.print("error: {s}: {s}\n", .{ project.at(file).input.name, run_error.why });
            } else try writer.print("error: {s}\n", .{run_error.why});
            for (self.stale) |stale| try writer.print("suppression: {s}:{d}:{d}: {s} suppresses nothing\n", .{ project.at(stale.span.file).input.name, stale.span.line, stale.span.column, stale.name });
            for (self.malformed) |entry| try writer.print("{t}: {s}:{d}:{d}: malformed: {s}\n", .{ entry.of, project.at(entry.span.file).input.name, entry.span.line, entry.span.column, entry.why });
            for (self.seams) |seam| {
                try writer.print("seam: {s}: {s}: ", .{ seam.where, seam.reason });
                for (seam.rules, 0..) |rule, i| try writer.print("{s}{s} {d}", .{ if (i == 0) "" else ", ", rule.name, rule.sites });
                try writer.writeAll(if (seam.stale) " (stale: it holds no site)\n" else "\n");
            }
            for (self.test_inputs) |entry| try writer.print("test inputs: {s}: {d} files{s}\n", .{ entry.pattern, entry.files, if (entry.files == 0) " (stale)" else "" });
            if (self.metrics) |metrics| try textMetrics(writer, metrics);
        },
        .json => {
            try writer.print("{{\"version\":1,\"analysis_complete\":{s},\"suppressed\":{d},\"stale_suppressions\":{d},\"stale\":[", .{ if (self.complete) "true" else "false", self.suppressed, self.stale.len });
            for (self.stale, 0..) |stale, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.at(stale.span.file).input.name, .rule = stale.name, .line = stale.span.line, .column = stale.span.column }, .{}, writer);
            }
            try writer.writeAll("],\"malformed\":[");
            for (self.malformed, 0..) |entry, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = project.at(entry.span.file).input.name, .line = entry.span.line, .column = entry.span.column, .why = entry.why }, .{}, writer);
            }
            try writer.writeAll("],\"diagnostics\":[");
            for (self.diagnostics, 0..) |d, i| {
                if (i != 0) try writer.writeByte(',');
                try jsonDiagnostic(writer, project, d); // safe: enum identities index their owning frozen tables without narrowing.
            }
            try writer.writeAll("],\"errors\":[");
            for (self.errors, 0..) |e, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .source = if (e.file) |file| project.at(file).input.name else null, .why = e.why }, .{}, writer);
            }
            try writer.writeAll("],\"seams\":");
            try std.json.Stringify.value(self.seams, .{}, writer);
            try writer.writeAll(",\"test_inputs\":");
            try std.json.Stringify.value(self.test_inputs, .{}, writer);
            if (self.metrics) |metrics| {
                try writer.writeAll(",\"metrics\":{");
                try jsonCounts(writer, metrics.total);
                try writer.writeAll(",\"files\":[");
                for (metrics.files, 0..) |entry, i| {
                    if (i != 0) try writer.writeByte(',');
                    try writer.writeAll("{\"source\":");
                    try std.json.Stringify.value(project.at(entry.file).input.name, .{}, writer);
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
                try std.json.Stringify.value(.{ .file = @backingInt(stale.span.file), .rule = stale.name, .start = stale.span.start, .line = stale.span.line, .column = stale.span.column }, .{}, writer);
            }
            try writer.writeAll("],\"errors\":");
            try writer.writeByte('[');
            for (self.errors, 0..) |e, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(.{ .file = if (e.file) |file| @as(?u32, @backingInt(file)) else null, .why = e.why }, .{}, writer);
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
    try writer.writeByte('\n');
}

fn jsonCounts(writer: *std.Io.Writer, counts: Metrics.Counts) std.Io.Writer.Error!void {
    try writer.print("\"functions\":{d},\"asserted\":{d},\"assertions\":{{", .{ counts.functions, counts.asserted });
    for (std.meta.tags(Metrics.Kind), counts.assertions, 0..) |kind, n, i| try writer.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", kind.label(), n });
    try writer.writeByte('}');
}

fn jsonDiagnostic(writer: *std.Io.Writer, project: *const Project, d: Diagnostic) std.Io.Writer.Error!void {
    var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
    const record = .{ .rule = d.name, .rule_version = d.rule_version, .class = d.class, .severity = d.severity, .source = project.at(d.span.file).input.name, .span = wireSpan(d.span), .level = d.level, .message = d.message, .bug_class = d.bug_class };
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
    try writeUri(stream, project.at(span.file).input.name);
    try stream.endObject();
    try stream.objectField("region");
    // Byte offsets stay precise for non-ASCII and invalid UTF-8 source. A byte
    // column is not mislabeled as SARIF's default UTF-16 column.
    const length = if (span.end > span.start) span.end - span.start else 0;
    try stream.write(.{ .startLine = span.line, .byteOffset = span.start, .byteLength = length });
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
        } else try stream.write(.{ .source = project.at(span.file).input.name, .span = wireSpan(span) });
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
    return .{ .file = @backingInt(span.file), .start = span.start, .end = span.end, .line = span.line, .column = span.column };
}
