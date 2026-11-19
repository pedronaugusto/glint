//! Public contracts: allocation failures, arbitrary parser input and rendering.
const std = @import("std");
const glint = @import("glint");
/// What a suppression's comment opens with, the rules it names following it.
const ignore = "// " ++ glint.suppression_keyword ++ ": ";
const shakedown = @import("shakedown");

test "contract allocation failures release project and report owners" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var project = try glint.Project.init(a, &.{.{ .name = "fixture", .bytes = "const d = @import(\"dep\"); pub fn f() void {}" }}, &.{}, .{});
            defer project.deinit();
            var report = try glint.run(a, &project, .{ .config = glint.Config.reviewed() });
            defer report.deinit();
            var output: std.Io.Writer.Allocating = .init(a);
            defer output.deinit();
            report.write(&output.writer, &project, .json) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            }; // Allocating has no failure other than allocation.
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Case.run, .{});
}

test "contract seeded arbitrary bytes parse with bounded public ownership" {
    const Property = struct {
        fn run(_: void, case: *shakedown.Case) !void {
            var bytes: [128]u8 = undefined;
            const count = shakedown.gen.intRange(case.source, usize, 0, bytes.len);
            for (bytes[0..count]) |*byte| byte.* = shakedown.gen.int(case.source, u8);
            var project = try glint.Project.init(case.gpa, &.{.{ .name = "arbitrary", .bytes = bytes[0..count] }}, &.{}, .{});
            defer project.deinit();
            var report = try glint.run(case.gpa, &project, .{});
            defer report.deinit();
            for (report.diagnostics) |diagnostic| {
                try std.testing.expect(diagnostic.span.start <= count);
                try std.testing.expect(diagnostic.span.end <= count);
            }
        }
    };
    try shakedown.check(std.testing.allocator, {}, Property.run, .{
        .cases = 64,
        // `fQ:0x.p1`: a hex float with no digit, which std's lowering unwrapped (release run 44210310859).
        // `0.0_000E94`: a decimal float whose underscores std's slow path misreads into an i32
        // overflow, inside the check that guards lowering (release run 44602405148).
        .regressions = &.{ "8:66:51:3a:30:78:2e:70:31", "a:30:2e:30:5f:30:30:30:45:39:34" },
    });
}

// std.fmt.parseFloat's slow path misreads a decimal float's underscores (Zig 0.17): it records
// zeros it means to skip and trims trailing zeros at an index that leaves the underscores out.
// AstGen hands it the token as written, so such a literal is refused before anything reads it;
// one std reads as its digits alone is lowered.
test "contract a decimal float std misreads by its underscores is refused; one it reads is lowered" {
    const refused = [_][]const u8{ "0.0_000E94", "0.0_05e94", "0.0_0e-94", "0.000_000_1e-50", "1.0_05e94" };
    for (refused) |literal| {
        var source: [64]u8 = undefined;
        const code_text = try std.mem.print(&source, "const x = {s};", .{literal});
        var code = try glint.Project.init(std.testing.allocator, &.{.{ .name = "float", .bytes = code_text }}, &.{}, .{});
        defer code.deinit();
        std.testing.expectEqual(.invalid_lowering, code.sources[0].file.status) catch |err| {
            std.debug.print("lowered: {s}\n", .{literal});
            return err;
        };
        const data_text = try std.mem.print(&source, ".{{ .x = {s} }}", .{literal});
        var data = try glint.Project.init(std.testing.allocator, &.{.{ .name = "float", .bytes = data_text, .kind = .zon }}, &.{}, .{});
        defer data.deinit();
        try std.testing.expectEqual(.invalid_syntax, data.sources[0].file.status);
    }
    const lowered = [_][]const u8{ "0.000_001", "0.000_000_1", "1_000.5", "1_000e100", "3.141_592_653_589_793_238_462_643", "1.797_693_134_862_315_7e308", "6.022_140_76e23", "0x1_0.8p1", "0.00_1E94" };
    for (lowered) |literal| {
        var source: [64]u8 = undefined;
        const text = try std.mem.print(&source, "const x = {s};", .{literal});
        var code = try glint.Project.init(std.testing.allocator, &.{.{ .name = "float", .bytes = text }}, &.{}, .{});
        defer code.deinit();
        std.testing.expectEqual(.parsed, code.sources[0].file.status) catch |err| {
            std.debug.print("refused: {s}\n", .{literal});
            return err;
        };
    }
}

// Any decimal float with underscores between its digits is lowered or refused, never a trap: a
// literal the check passes reaches AstGen, which reads it with parseFloat as written.
test "contract seeded decimal floats with underscores never trap the lowering" {
    const Property = struct {
        fn digits(case: *shakedown.Case, text: *std.ArrayList(u8), zeros: bool) !void {
            const count = shakedown.gen.intRange(case.source, usize, 1, 40);
            for (0..count) |i| {
                if (i != 0 and shakedown.gen.intRange(case.source, u8, 0, 3) == 0) try text.append(case.gpa, '_');
                const digit: u8 = if (zeros and shakedown.gen.boolean(case.source)) 0 else shakedown.gen.intRange(case.source, u8, 0, 9);
                try text.append(case.gpa, '0' + digit);
            }
        }
        fn run(_: void, case: *shakedown.Case) !void {
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(case.gpa);
            try text.appendSlice(case.gpa, "const x = ");
            const zeros = shakedown.gen.boolean(case.source);
            if (shakedown.gen.boolean(case.source)) try text.append(case.gpa, '0') else try digits(case, &text, zeros);
            try text.append(case.gpa, '.');
            try digits(case, &text, zeros);
            if (shakedown.gen.boolean(case.source)) {
                const exponent = shakedown.gen.intRange(case.source, i32, -6000, 6000);
                try text.print(case.gpa, "e{d}", .{exponent});
            }
            try text.appendSlice(case.gpa, ";");
            case.note("{s}", .{text.items});
            var project = try glint.Project.init(case.gpa, &.{.{ .name = "float", .bytes = text.items }}, &.{}, .{});
            defer project.deinit();
            const status = project.sources[0].file.status;
            try std.testing.expect(status == .parsed or status == .invalid_lowering);
        }
    };
    try shakedown.check(std.testing.allocator, {}, Property.run, .{ .cases = 2048 });
}

// std.zig.parseNumberLiteral calls `0x.p1` a float and std.fmt.parseFloat refuses it, which
// AstGen and ZonGen unwrap: such a file is refused before lowering, as Zig and as ZON.
test "contract a float std's lowering cannot read is refused, not lowered" {
    var code = try glint.Project.init(std.testing.allocator, &.{.{ .name = "float", .bytes = "const x = 0x.p1;" }}, &.{}, .{});
    defer code.deinit();
    try std.testing.expectEqual(.invalid_lowering, code.sources[0].file.status);
    var data = try glint.Project.init(std.testing.allocator, &.{.{ .name = "float", .bytes = ".{ .x = 0x.p1 }", .kind = .zon }}, &.{}, .{});
    defer data.deinit();
    try std.testing.expectEqual(.invalid_syntax, data.sources[0].file.status);
}

test "contract JSON and SARIF preserve stable IDs and reasoned suppressions" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .bytes = "const one = @import(\"one\");\n" ++ ignore ++ "Z013 -- test-only retained declaration\nconst two = @import(\"two\");" }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: explicit compile-time type selection; the value is representable in that type.
    for ([_]glint.Report.Format{ .json, .sarif }) |format| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try report.write(&output.writer, &project, format);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try std.testing.expect(std.mem.find(u8, output.written(), "Z013") != null);
    }
}

test "contract SARIF names the version of glint the manifest gives" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .bytes = "pub const x = 1;" }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.run(std.testing.allocator, &project, .{});
    defer report.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try report.write(&output.writer, &project, .sarif);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const driver = parsed.value.object.get("runs").?.array.items[0].object.get("tool").?.object.get("driver").?.object;
    try std.testing.expectEqualStrings(glint.version, driver.get("version").?.string);
    _ = try std.SemanticVersion.parse(glint.version);
}

test "contract a report cannot silently render against another project snapshot" {
    var first = try glint.Project.init(std.testing.allocator, &.{.{ .name = "first", .bytes = "const d = @import(\"dep\");" }}, &.{}, .{});
    defer first.deinit();
    var other = try glint.Project.init(std.testing.allocator, &.{.{ .name = "other", .bytes = "pub const x = 1;" }}, &.{}, .{});
    defer other.deinit();
    var report = try glint.run(std.testing.allocator, &first, .{});
    defer report.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidProject, report.write(&output.writer, &other, .json));
}

test "contract deprecation diagnostic carries its resolved declaration span" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture label", .bytes = "/// Deprecated: use fresh.\nfn old() void {} pub fn run() void { old(); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z011, true);
    var report = try glint.run(std.testing.allocator, &project, .{ .config = config });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: expected single fixture diagnostic fits usize.
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics[0].related.len); // safe: expected single declaration span fits usize.
    try std.testing.expectEqual(@as(u32, 30), report.diagnostics[0].related[0].start); // safe: the declaration name begins at byte 30 of the fixed fixture.
    for ([_]glint.Report.Format{ .json, .sarif }) |format| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try report.write(&output.writer, &project, format);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
        defer parsed.deinit();
        if (format == .json) {
            const related = parsed.value.object.get("diagnostics").?.array.items[0].object.get("related").?.array.items[0];
            try std.testing.expectEqualStrings("fixture label", related.object.get("source").?.string);
        } else {
            const diagnostic = parsed.value.object.get("runs").?.array.items[0].object.get("results").?.array.items[0];
            const location = diagnostic.object.get("relatedLocations").?.array.items[0].object.get("physicalLocation").?;
            try std.testing.expectEqualStrings("fixture%20label", location.object.get("artifactLocation").?.object.get("uri").?.string);
            try std.testing.expectEqual(@as(i64, 30), location.object.get("region").?.object.get("byteOffset").?.integer); // safe: byte 30 of the fixed fixture fits i64.
        }
    }
}

test "contract G2 allocation failures release dead-private owners" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var project = try glint.Project.init(a, &.{.{ .name = "model", .bytes = "fn unused() void {} pub fn live() void {}" }}, &.{}, .{});
            defer project.deinit();
            var config = glint.Config.none();
            config.set(.D001, true);
            var report = try glint.run(a, &project, .{ .config = config });
            defer report.deinit();
            try std.testing.expect(report.complete);
            try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: known private unused fixture function.
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Case.run, .{});
}

test "contract invalid lowering never indexes partial ZIR declaration payloads" {
    var invalid = try glint.Project.init(std.testing.allocator, &.{.{ .name = "invalid", .bytes = "pub fn make() Unknown { return .{}; }" }}, &.{}, .{});
    defer invalid.deinit();
    try std.testing.expectEqual(.invalid_lowering, invalid.sources[0].file.status);
    try std.testing.expectEqual(@as(usize, 0), invalid.sources[0].model.zir_declarations.len); // safe: rejected lowering has no admitted declaration payloads.
    var report = try glint.run(std.testing.allocator, &invalid, .{});
    defer report.deinit();
    try std.testing.expect(!report.complete);
    var valid = try glint.Project.init(std.testing.allocator, &.{.{ .name = "valid", .bytes = "pub fn make() u8 { return 1; }" }}, &.{}, .{});
    defer valid.deinit();
    try std.testing.expect(valid.sources[0].model.zir_declarations.len != 0);
}

test "project allocation failures release partially initialized files" {
    const Helper = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var project = try glint.Project.init(gpa, &.{.{ .name = "root", .bytes = "const x = 1;" }}, &.{}, .{});
            defer project.deinit();
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Helper.run, .{});
}

test "morning token allocation failures and arbitrary input release all owners" {
    const Property = struct {
        fn run(_: void, case: *shakedown.Case) !void {
            var bytes: [256]u8 = undefined;
            const n = shakedown.gen.intRange(case.source, usize, 0, bytes.len);
            for (bytes[0..n]) |*byte| byte.* = shakedown.gen.int(case.source, u8);
            var arena = std.heap.ArenaAllocator.init(case.gpa);
            defer arena.deinit();
            const facts = glint.token.scan(arena.allocator(), bytes[0..n], null) catch |err| switch (err) {
                error.InvalidLiteral => return,
                else => return err,
            };
            for (facts.imports) |imp| try std.testing.expect(imp.offset <= n);
        }
        fn allocations(a: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            _ = try glint.token.scan(arena.allocator(), "const d = @import(\"dep\"); pub fn f() void { _ = d.read; }", null);
        }
    };
    try shakedown.check(std.testing.allocator, {}, Property.run, .{ .cases = 256 });
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Property.allocations, .{});
}

test "token allocation failures cover bounded temporary buffer spilling" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var bytes: [1024]u8 = undefined;
            var source: std.Io.Writer = .fixed(&bytes);
            try source.writeAll("pub fn f() void {");
            for (0..70) |_| try source.writeAll("_ = 0; ");
            try source.writeAll("_ = @import(\"dep\"); }");
            const facts = try glint.token.scan(arena.allocator(), source.buffered(), null);
            try std.testing.expectEqual(@as(usize, 1), facts.imports.len); // safe: dense short source contains one import after temporary storage spills.
            try std.testing.expect(!facts.imports[0].dead);
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Case.run, .{});
}
