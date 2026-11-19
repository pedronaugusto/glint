//! The program contract: what a caller that runs glint as a program writes (the project file)
//! and reads back (the report, the result record, the surface lines), by version. A change is
//! additive where it can be and keeps its version; a breaking one is read beside the old for
//! exactly one release, and the release after deletes the old reader (docs/design.md, "The
//! program contract").
const std = @import("std");
const Rule = @import("Rule.zig");
const Config = Rule.Config;

/// The project-file versions this glint reads, oldest first: two only inside a window.
pub const versions = [_]u32{1};

/// `glint --contract`'s answer, the line a caller parses before it writes a project file:
/// `glint-contract` and each version this glint reads.
pub fn writeVersions(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("glint-contract");
    for (versions) |version| try writer.print(" {d}", .{version});
    try writer.writeByte('\n');
}

/// glint's configuration schema, the one glint.json uses and a project file's `policy.config`
/// carries: the profile, rule levels and code options. Strict JSON; callers own file selection.
pub const Configuration = struct {
    /// `core`, `none` or `reviewed`; 0.7's `aegis` and `family` are refused with what to
    /// write instead.
    profile: []const u8 = "core",
    rules: []const Setting = &.{},
    max_line_length: u32 = 100,
    max_function_lines: u32 = 120,
    max_parameters: u32 = 7,
    max_nesting: u32 = 5,
    max_stack_array: u64 = 64 * 1024,
    function_exceptions: []const Config.FunctionException = &.{},
    disallowed: []const Config.Disallowed = &.{},
    strict_suppressions: bool = false,
    metrics: bool = false,
    fact_budget: usize = 100_000,
    seams: []const Config.Seam = &.{},
    test_inputs: []const Config.TestInput = &.{},
    pub const Setting = struct { id: []const u8, level: Config.Level };
};

/// A configuration in glint's schema as it was written: each field it sets, and null for each it
/// leaves out, so the caller's value holds where it is silent. A field the schema does not have
/// is refused, as `Configuration` refuses it.
pub const Written = struct {
    profile: ?[]const u8 = null,
    rules: ?[]const Configuration.Setting = null,
    max_line_length: ?u32 = null,
    max_function_lines: ?u32 = null,
    max_parameters: ?u32 = null,
    max_nesting: ?u32 = null,
    max_stack_array: ?u64 = null,
    function_exceptions: ?[]const Config.FunctionException = null,
    disallowed: ?[]const Config.Disallowed = null,
    strict_suppressions: ?bool = null,
    metrics: ?bool = null,
    fact_budget: ?usize = null,
    seams: ?[]const Config.Seam = null,
    test_inputs: ?[]const Config.TestInput = null,

    comptime {
        // One schema: a field `Configuration` gains is a field a written one may set.
        const ours = @typeInfo(Written).@"struct".field_names;
        const theirs = @typeInfo(Configuration).@"struct".field_names;
        if (ours.len != theirs.len) @compileError("Written and Configuration differ");
        for (ours, theirs) |mine, other| if (!std.mem.eql(u8, mine, other)) @compileError("Written and Configuration differ at " ++ other);
    }
};

/// A project file, version 1: what a caller that runs glint as a program hands it. Paths are
/// relative to `root`. The caller owns its configuration and the build graph; glint owns what is
/// read from them (docs/design.md, "The program contract").
pub const ProjectFile = struct {
    version: u32,
    root: []const u8,
    zig_lib: ?[]const u8 = null,
    /// Shipped bans fail (the release tier); nothing else.
    release: bool = false,
    modules: []const Module = &.{},
    exported: []const Exported = &.{},
    files: []const File,
    policy: Policy,

    /// A module of the build: its root (null where the build makes it), a generated root's text,
    /// whether the build runner compiles it, and the names it binds, by index into `modules`.
    pub const Module = struct {
        root: ?[]const u8 = null,
        contents: ?[]const u8 = null,
        script: bool = false,
        imports: []const Binding = &.{},
    };
    pub const Binding = struct { name: []const u8, module: usize };
    /// A module the package exports, by the name a consumer imports it by.
    pub const Exported = struct { name: []const u8, root: []const u8 };
    pub const File = struct {
        path: []const u8,
        kind: Kind,
        /// In what build.zig.zon ships: the shipped bans and the packages' bans hold it.
        ships: bool,
        /// Null: P003 is off here.
        max_function_lines: ?u32,
        function_exceptions: []const FunctionException = &.{},
        /// A file the caller verified as its upstream's copy.
        vendored: ?Vendored = null,
    };
    pub const Kind = enum { production, @"test", support };
    pub const FunctionException = Config.FunctionException;
    pub const Vendored = struct { upstream: []const u8, verification: []const u8 };
    /// The levels the caller weighs the rules at, and what no in-repo configuration may lower.
    /// glint is told a floor, never whose it is.
    pub const Policy = struct {
        /// The caller's default table: glint's own ids, each at its weight.
        levels: []const LevelEntry,
        /// Null: no floor, and an amendment below a default is a note.
        floor: ?Floor = null,
        /// The bans that hold what the package ships (`File.ships`), beside the packages' bans.
        shipped_bans: []const []const u8,
        disallowed: []const Disallowed = &.{},
        fact_budget: usize,
        /// A suppression that suppresses nothing leaves the run incomplete.
        strict_suppressions: bool = false,
        /// Each selected file's functions and assertion calls are counted into the report.
        metrics: bool = false,
        /// The in-repo configuration in glint's own schema (glint.json's), as written: its rules
        /// amend `levels`, the code options it writes apply.
        config: ?Written = null,
        /// The repository's glint.json, by its path from `root`, or null.
        repo_options: ?[]const u8 = null,
    };
    /// The rules and weights no in-repo configuration may lower; whether each package's declared
    /// rule is held at its own default; whether a repository's glint.json is refused.
    pub const Floor = struct {
        rules: []const LevelEntry = &.{},
        package_defaults: bool = false,
        refuse_repo_options: bool = false,
    };
    pub const Weight = enum { gate, finding, report, off };
    pub const LevelEntry = struct { rule: []const u8, weight: Weight };
    pub const Disallowed = Config.Disallowed;
};

pub const ReadError = error{ OutOfMemory, UnsupportedVersion, InvalidProjectFile };

/// The project file `bytes` holds, its version read first so a version this glint does not read
/// is refused as that: what is wrong is written to `problems`. Unknown fields are refused: a
/// field this glint does not read would be a setting nobody applies.
pub fn readProject(a: std.mem.Allocator, bytes: []const u8, problems: *std.Io.Writer) (ReadError || std.Io.Writer.Error)!ProjectFile {
    const Head = struct { version: ?u32 = null };
    const head = std.json.parseFromSliceLeaky(Head, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try problems.print("project file: not JSON with a numeric `version` ({t})\n", .{err});
            return error.InvalidProjectFile;
        },
    };
    const version = head.version orelse {
        try problems.writeAll("project file: no `version`\n");
        return error.InvalidProjectFile;
    };
    if (std.mem.findScalar(u32, &versions, version) == null) {
        try problems.print("project file: version {d}, which this glint does not read; it reads", .{version});
        for (versions) |known| try problems.print(" {d}", .{known});
        try problems.writeAll(" (glint --contract)\n");
        return error.UnsupportedVersion;
    }
    var diagnostics: std.json.Diagnostics = .{};
    var scanner: std.json.Scanner = .initCompleteInput(a, bytes);
    scanner.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSourceLeaky(ProjectFile, a, &scanner, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try problems.print("project file: {d}:{d}: not a version {d} project file ({t})\n", .{ diagnostics.getLine(), diagnostics.getColumn(), version, err });
            return error.InvalidProjectFile;
        },
    };
}

/// The smallest project file version 1 reads: what a test writes on.
const minimal =
    \\{"version": 1, "root": ".", "files": [{"path": "a.zig", "kind": "production", "ships": true, "max_function_lines": 120}],
    \\ "policy": {"levels": [{"rule": "Z003", "weight": "gate"}], "shipped_bans": ["P007"], "fact_budget": 4000000}}
;

test "a version 1 project file reads, its defaults filled" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    const project = try readProject(arena.allocator(), minimal, &problems.writer);
    try std.testing.expectEqual(@as(u32, 1), project.version);
    try std.testing.expectEqual(ProjectFile.Kind.production, project.files[0].kind);
    try std.testing.expectEqual(@as(?u32, 120), project.files[0].max_function_lines);
    try std.testing.expect(!project.release);
    try std.testing.expectEqual(ProjectFile.Weight.gate, project.policy.levels[0].weight);
    try std.testing.expectEqualStrings("", problems.written());
}

test "a version this glint does not read is refused as that, naming what it reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.UnsupportedVersion, readProject(arena.allocator(), "{\"version\": 2, \"anything\": true}", &problems.writer));
    try std.testing.expectEqualStrings("project file: version 2, which this glint does not read; it reads 1 (glint --contract)\n", problems.written());
}

test "an unknown field is refused, never ignored: it would be a setting nobody applies" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    const extra = "{\"version\": 1, \"root\": \".\", \"files\": [], \"policy\": {\"levels\": [], \"shipped_bans\": [], \"fact_budget\": 1}, \"strict\": false}";
    try std.testing.expectError(error.InvalidProjectFile, readProject(arena.allocator(), extra, &problems.writer));
    try std.testing.expect(std.mem.startsWith(u8, problems.written(), "project file: 1:"));
}

test "fuzz: the project file" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [4096]u8 = undefined;
            const bytes = buffer[0..smith.slice(&buffer)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var discard: [256]u8 = undefined;
            var problems: std.Io.Writer.Discarding = .init(&discard);
            // A file refused is the answer: the CLI says why.
            _ = readProject(arena.allocator(), bytes, &problems.writer) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
        }
    };
    try std.testing.fuzz({}, Target.one, .{ .corpus = &.{
        minimal,
        "{\"version\": 2}",
        "{\"version\": 1, \"root\": \".\", \"modules\": [{\"root\": null, \"contents\": \"pub const x = 1;\", \"imports\": [{\"name\": \"a\", \"module\": 0}]}], \"files\": [], \"policy\": {\"levels\": [], \"floor\": {\"rules\": [{\"rule\": \"Z026\", \"weight\": \"gate\"}], \"package_defaults\": true}, \"shipped_bans\": [], \"fact_budget\": 1, \"config\": {\"rules\": [{\"id\": \"Z026\", \"level\": \"report\"}]}}}",
        "{",
    } });
}

test "the contract's answer is one plain line a caller parses" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeVersions(&writer);
    try std.testing.expectEqualStrings("glint-contract 1\n", writer.buffered());
}
