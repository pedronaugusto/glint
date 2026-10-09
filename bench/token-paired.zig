//! Exact frozen-baseline parity and alternating timing pairs; IO/loading stays outside timing.
const std = @import("std");
const fast = @import("glint_token");
const old = @import("baseline");
const Stats = @import("allocations.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var inputs: std.ArrayList([:0]const u8) = .empty;
    if (args.len > 1) {
        const manifest = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .unlimited);
        var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
        while (lines.next()) |path| try inputs.append(a, try std.Io.Dir.cwd().readFileAllocOptions(init.io, path, a, .unlimited, .of(u8), 0));
    } else try inputs.append(a, "const dep = @import(\"dep\"); pub fn f() void { _ = dep.read; }");
    var bytes: usize = 0;
    var imports: usize = 0;
    for (inputs.items) |source| {
        bytes += source.len;
        var scratch = std.heap.ArenaAllocator.init(init.gpa);
        defer scratch.deinit();
        const baseline = try old.recover(scratch.allocator(), source);
        const next = try fast.scanSentinel(scratch.allocator(), source, null);
        if (baseline.specs.len != next.imports.len) {
            return error.ImportCountMismatch;
        }
        for (baseline.specs, next.imports) |l, r| {
            if (!std.mem.eql(u8, l.name, r.name) or l.offset != r.offset or l.dead != r.dead or (l.kind == .@"test") != (r.kind == .@"test")) return error.ImportMismatch;
            if ((l.member == null) != (r.member == null)) return error.MemberMismatch;
            if (l.member) |member| if (!std.mem.eql(u8, member, r.member.?)) return error.MemberMismatch;
            if (l.form != .literal or l.scope.len != 0 or l.python_base or l.star) return error.UnexpectedBaselineFact;
        }
        if (baseline.unsupported.len != next.unsupported.len) return error.CoverageMismatch;
        for (baseline.unsupported, next.unsupported) |l, r| if (l.offset != r.offset or l.expression != .zig_import or r.expression != .zig_import) return error.CoverageMismatch;
        imports += next.imports.len;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print("files={d} bytes={d} imports={d} parity=exact\n", .{ inputs.items.len, bytes, imports });
    const rounds: usize = if (args.len > 1) 1 else 2000;
    for (0..20) |pair| {
        var times: [2]i96 = undefined;
        for (0..2) |position| {
            const which = (position + pair) % 2;
            const start = std.Io.Clock.awake.now(init.io);
            for (0..rounds) |_| for (inputs.items) |source| {
                var scratch = std.heap.ArenaAllocator.init(init.gpa);
                defer scratch.deinit();
                if (which == 0) {
                    const facts = try old.recover(scratch.allocator(), source);
                    std.mem.doNotOptimizeAway(facts.specs.ptr);
                } else {
                    const facts = try fast.scanSentinel(scratch.allocator(), source, null);
                    std.mem.doNotOptimizeAway(facts.imports.ptr);
                }
            };
            times[which] = start.durationTo(std.Io.Clock.awake.now(init.io)).toNanoseconds();
        }
        try out.interface.print("pair={d} rounds={d} baseline_ns={d} token_ns={d}\n", .{ pair, rounds, times[0], times[1] });
    }
    inline for (.{ false, true }) |candidate| {
        var stats: Stats = .{ .backing = init.gpa };
        for (inputs.items) |source| {
            var scratch = std.heap.ArenaAllocator.init(stats.allocator());
            if (candidate) {
                const facts = try fast.scanSentinel(scratch.allocator(), source, null);
                std.mem.doNotOptimizeAway(facts.imports.ptr);
            } else {
                const facts = try old.recover(scratch.allocator(), source);
                std.mem.doNotOptimizeAway(facts.specs.ptr);
            }
            scratch.deinit();
            if (stats.live != 0) return error.LeakedOwner;
        }
        try out.interface.print("memory={s} allocations={d} peak_requested_bytes={d} live_after={d}\n", .{ if (candidate) "token" else "baseline", stats.allocations, stats.peak, stats.live });
    }
    try out.interface.flush();
}
