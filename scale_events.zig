const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Pos = struct { x: f32 = 0, y: f32 = 0 };
const T0 = struct {};
const T1 = struct {};
const Damage = struct { amount: u32 = 0 };

// Single archetype: worst case, all events land in one page.
const Ecs1 = ecs_module.ECS(.{.{Pos}});
// Four archetypes: spread case, events split over four pages.
const Ecs4 = ecs_module.ECS(.{
    .{Pos},
    .{ Pos, T0 },
    .{ Pos, T1 },
    .{ Pos, T0, T1 },
});

// Smaller ladder in Debug: low per-op constants dominate there.
const Ns: []const usize = if (builtin.mode == .Debug)
    &.{ 500, 1000, 2000 }
else
    &.{ 10000, 25000, 50000, 100000 };

// Repetitions per scenario: first run is cold (growth, allocator caches),
// best of the rest is the warm steady state the gate is measured against.
const REPS: usize = if (builtin.mode == .Debug) 2 else 3;

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// Monotonic bench clock via the global single-threaded Io backend.
/// No threads are spawned; resolution is platform-provided.
fn benchIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn stamp() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(benchIo(), .awake);
}
fn nsSince(t0: std.Io.Clock.Timestamp) u64 {
    const d = t0.durationTo(stamp());
    return @intCast(d.raw.toNanoseconds());
}

fn spawn1(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *Ecs1.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
        }
    };
    S.count = n;
    try Ecs1.Schedule(.{S.spawn}).run(allocator);
}

fn spawn4(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *Ecs4.SystemHandler) anyerror!void {
            const q: u32 = S.count / 4;
            const r: u32 = S.count - q * 4;
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, q + r);
            _ = try h.cmdCreateN(&[_]type{ Pos, T0 }, .{ Pos{}, T0{} }, q);
            _ = try h.cmdCreateN(&[_]type{ Pos, T1 }, .{ Pos{}, T1{} }, q);
            _ = try h.cmdCreateN(&[_]type{ Pos, T0, T1 }, .{ Pos{}, T0{}, T1{} }, q);
        }
    };
    S.count = n;
    try Ecs4.Schedule(.{S.spawn}).run(allocator);
}

fn countEvents(comptime E: type, allocator: std.mem.Allocator) usize {
    const handler = E.SystemHandler{ .allocator = allocator };
    var total: usize = 0;
    for (handler.allEvents(Damage)) |page| {
        total += page.count();
    }
    return total;
}

fn wipeWorld(comptime E: type, allocator: std.mem.Allocator) !void {
    const S = struct {
        fn wipe(h: *E.SystemHandler) anyerror!void {
            try h.cmdDestroyPages(&[_]type{Pos}, null);
        }
    };
    try E.Schedule(.{S.wipe}).run(allocator);
}

/// One frame { emit, check }: emit is timed inline (queueSet path),
/// total covers queue + flush upsert + check + frame-end clear.
/// flush ~= total - emit (check is one linear pass).
fn benchEmit(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { emit_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var emit_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            const t0 = stamp();
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 1 });
                }
            }
            S.emit_ns = nsSince(t0);
        }
        fn check(h: *E.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.want_count);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.check }).run(allocator);
    return .{ .emit_ns = S.emit_ns, .total_ns = nsSince(t0) };
}

/// One frame { emit, read }: read is timed inline and verifies payloads.
/// read ~= pure consume cost (linear).
fn benchRead(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { read_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var read_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 3 });
                }
            }
        }
        fn read(h: *E.SystemHandler) anyerror!void {
            const t0 = stamp();
            var n: usize = 0;
            var sum: u64 = 0;
            for (h.allEvents(Damage)) |page| {
                n += page.count();
                for (page.eventList()) |ev| {
                    sum += ev.amount;
                }
            }
            S.read_ns = nsSince(t0);
            try std.testing.expect(n == S.want_count);
            try std.testing.expect(sum == 3 * S.want_count);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.read }).run(allocator);
    return .{ .read_ns = S.read_ns, .total_ns = nsSince(t0) };
}

/// One frame { emit, wipe }: wipe times queueDestroy per handle (findByEntity
/// path); flush remove cost lands in total (total - emit - wipe ~= remove).
fn benchDestroyEach(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { wipe_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var wipe_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 1 });
                }
            }
        }
        fn wipe(h: *E.SystemHandler) anyerror!void {
            const seen = blk: {
                var n: usize = 0;
                for (h.allEvents(Damage)) |page| {
                    n += page.count();
                }
                break :blk n;
            };
            try std.testing.expect(seen == S.want_count);
            const t0 = stamp();
            for (h.allEvents(Damage)) |page| {
                for (0..page.count()) |i| {
                    try h.cmdDestroyEvent(page.handleAt(i));
                }
            }
            S.wipe_ns = nsSince(t0);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.wipe }).run(allocator);
    return .{ .wipe_ns = S.wipe_ns, .total_ns = nsSince(t0) };
}

/// One frame { emit, kill }: kill queues entity destroys (cheap); the event
/// purge runs in flush, so purge ~= total - emit - kill.
fn benchPurge(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { kill_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var kill_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 1 });
                }
            }
        }
        fn kill(h: *E.SystemHandler) anyerror!void {
            try std.testing.expect(countEvents(E, h.allocator) == S.want_count);
            const t0 = stamp();
            try h.cmdDestroyPages(&[_]type{Pos}, null);
            S.kill_ns = nsSince(t0);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.kill }).run(allocator);
    return .{ .kill_ns = S.kill_ns, .total_ns = nsSince(t0) };
}

const MAXN: usize = 100000;
var bench_refs: [MAXN]Ecs1.EntityReference = undefined;

fn spawn1refs(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *Ecs1.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
            for (created, 0..) |ref, i| {
                bench_refs[i] = ref;
            }
        }
    };
    S.count = n;
    try Ecs1.Schedule(.{S.spawn}).run(allocator);
}

/// S7: one cmdSetEvents call for all entities. Compares against S1's
/// per-entity loop (validate-once + single reservation vs N appends).
fn benchBatchSet(allocator: std.mem.Allocator, n: usize) !struct { emit_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var emit_ns: u64 = 0;
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            const t0 = stamp();
            try h.cmdSetEvents(bench_refs[0..want_n], Damage, .{ .amount = 4 });
            S.emit_ns = nsSince(t0);
        }
        fn check(h: *Ecs1.SystemHandler) anyerror!void {
            var total: usize = 0;
            var sum: u64 = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
                for (page.eventList()) |ev| {
                    sum += ev.amount;
                }
            }
            try std.testing.expect(total == S.want_n);
            try std.testing.expect(sum == 4 * S.want_n);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.check }).run(allocator);
    return .{ .emit_ns = S.emit_ns, .total_ns = nsSince(t0) };
}

/// S8: one cmdDestroyEventsFor call for all entities. Compares against S3's
/// per-handle loop.
fn benchBatchDestroy(allocator: std.mem.Allocator, n: usize) !struct { wipe_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var wipe_ns: u64 = 0;
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            try h.cmdSetEvents(bench_refs[0..want_n], Damage, .{ .amount = 1 });
        }
        fn wipe(h: *Ecs1.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.want_n);
            const t0 = stamp();
            try h.cmdDestroyEventsFor(bench_refs[0..want_n], Damage);
            S.wipe_ns = nsSince(t0);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.wipe }).run(allocator);
    return .{ .wipe_ns = S.wipe_ns, .total_ns = nsSince(t0) };
}

/// S10: emit, then wipe everything with one bulk call. Compares against S8's
/// per-entity destroy-for: O(pages) wipe instead of O(events) removes.
fn benchBulkDestroy(allocator: std.mem.Allocator, n: usize) !struct { wipe_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var wipe_ns: u64 = 0;
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            try h.cmdSetEvents(bench_refs[0..want_n], Damage, .{ .amount = 1 });
        }
        fn wipe(h: *Ecs1.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.want_n);
            const t0 = stamp();
            try h.cmdDestroyEvents(Damage);
            S.wipe_ns = nsSince(t0);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.wipe }).run(allocator);
    return .{ .wipe_ns = S.wipe_ns, .total_ns = nsSince(t0) };
}

test "bench S1: emit ladder (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    for (Ns) |n| {
        try spawn1(allocator, @intCast(n));
        var cold_emit: u64 = 0;
        var best_emit: u64 = std.math.maxInt(u64);
        var cold_frame: u64 = 0;
        var best_frame: u64 = std.math.maxInt(u64);
        for (0..REPS) |r| {
            const m = try benchEmit(Ecs1, allocator, n);
            if (r == 0) {
                cold_emit = m.emit_ns;
                cold_frame = m.total_ns;
            }
            best_emit = @min(best_emit, m.emit_ns);
            best_frame = @min(best_frame, m.total_ns);
        }
        std.debug.print("S1 emit 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_emit), ms(best_emit), ms(cold_frame), ms(best_frame) });
        try std.testing.expect(countEvents(Ecs1, allocator) == 0); // frame-end clear
        try wipeWorld(Ecs1, allocator);
    }
}

test "bench S2/S3: read and destroy-each at max N (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1(allocator, @intCast(n));
    var cold_read: u64 = 0;
    var best_read: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchRead(Ecs1, allocator, n);
        if (r == 0) {
            cold_read = m.read_ns;
        }
        best_read = @min(best_read, m.read_ns);
    }
    std.debug.print("S2 read 1-page N={d}: read cold {d:.3} / best {d:.3} ms\n", .{ n, ms(cold_read), ms(best_read) });
    var cold_wipe: u64 = 0;
    var best_wipe: u64 = std.math.maxInt(u64);
    var cold_wframe: u64 = 0;
    var best_wframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchDestroyEach(Ecs1, allocator, n);
        if (r == 0) {
            cold_wipe = m.wipe_ns;
            cold_wframe = m.total_ns;
        }
        best_wipe = @min(best_wipe, m.wipe_ns);
        best_wframe = @min(best_wframe, m.total_ns);
    }
    std.debug.print("S3 destroy-each 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_wipe), ms(best_wipe), ms(cold_wframe), ms(best_wframe) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S4: spread over 4 pages at max N" {
    const allocator = std.testing.allocator;
    defer Ecs4.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn4(allocator, @intCast(n));
    var cold_emit: u64 = 0;
    var best_emit: u64 = std.math.maxInt(u64);
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchEmit(Ecs4, allocator, n);
        if (r == 0) {
            cold_emit = m.emit_ns;
            cold_frame = m.total_ns;
        }
        best_emit = @min(best_emit, m.emit_ns);
        best_frame = @min(best_frame, m.total_ns);
    }
    std.debug.print("S1 emit 4-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_emit), ms(best_emit), ms(cold_frame), ms(best_frame) });
    var cold_read: u64 = 0;
    var best_read: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchRead(Ecs4, allocator, n);
        if (r == 0) {
            cold_read = m.read_ns;
        }
        best_read = @min(best_read, m.read_ns);
    }
    std.debug.print("S2 read 4-page N={d}: read cold {d:.3} / best {d:.3} ms\n", .{ n, ms(cold_read), ms(best_read) });
    var cold_wipe: u64 = 0;
    var best_wipe: u64 = std.math.maxInt(u64);
    var cold_wframe: u64 = 0;
    var best_wframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchDestroyEach(Ecs4, allocator, n);
        if (r == 0) {
            cold_wipe = m.wipe_ns;
            cold_wframe = m.total_ns;
        }
        best_wipe = @min(best_wipe, m.wipe_ns);
        best_wframe = @min(best_wframe, m.total_ns);
    }
    std.debug.print("S3 destroy-each 4-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_wipe), ms(best_wipe), ms(cold_wframe), ms(best_wframe) });
    try std.testing.expect(countEvents(Ecs4, allocator) == 0);
}

test "bench S5: full frame emit+consume+destroy (single page, max N)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1(allocator, @intCast(n));
    const S = struct {
        const S = @This();
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 2 });
                }
            }
        }
        fn consume(h: *Ecs1.SystemHandler) anyerror!void {
            var sum: u64 = 0;
            for (h.allEvents(Damage)) |page| {
                for (0..page.count()) |i| {
                    sum += page.valueAt(i).amount;
                    try h.cmdDestroyEvent(page.handleAt(i));
                }
            }
            try std.testing.expect(sum == 2 * S.want_n);
        }
    };
    S.want_n = n;
    var cold_frame: u64 = std.math.maxInt(u64);
    var best_frame: u64 = std.math.maxInt(u64);
    // First rep is cold; best of all reps is the warm steady state.
    var t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.consume }).run(allocator);
    cold_frame = nsSince(t0);
    best_frame = @min(best_frame, cold_frame);
    for (1..REPS) |_| {
        t0 = stamp();
        try Ecs1.Schedule(.{ S.emit, S.consume }).run(allocator);
        best_frame = @min(best_frame, nsSince(t0));
    }
    std.debug.print("S5 full frame 1-page N={d}: cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_frame), ms(best_frame) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S6b: destroy entities WITHOUT events (baseline, max N)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    const S = struct {
        const S = @This();
        var kill_ns: u64 = 0;
        fn kill(h: *Ecs1.SystemHandler) anyerror!void {
            const t0 = stamp();
            try h.cmdDestroyPages(&[_]type{Pos}, null);
            S.kill_ns = nsSince(t0);
        }
    };
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    var best_kill: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        try spawn1(allocator, @intCast(n));
        const t0 = stamp();
        try Ecs1.Schedule(.{S.kill}).run(allocator);
        const dt = nsSince(t0);
        if (r == 0) {
            cold_frame = dt;
        }
        best_frame = @min(best_frame, dt);
        best_kill = @min(best_kill, S.kill_ns);
    }
    std.debug.print("S6b destroy-no-events 1-page N={d}: kill-queue best {d:.3} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(best_kill), ms(cold_frame), ms(best_frame) });
}

test "bench S6: destroy entities carrying events (purge path, max N)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    var best_kill: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        try spawn1(allocator, @intCast(n));
        const m = try benchPurge(Ecs1, allocator, n);
        // benchPurge kills the entities it spawned for, so respawn next rep.
        if (r == 0) {
            cold_frame = m.total_ns;
        }
        best_frame = @min(best_frame, m.total_ns);
        best_kill = @min(best_kill, m.kill_ns);
        try std.testing.expect(countEvents(Ecs1, allocator) == 0);
    }
    std.debug.print("S6 purge 1-page N={d}: kill-queue best {d:.3} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(best_kill), ms(cold_frame), ms(best_frame) });
}

test "bench S9: lifecycle filing overhead (mass create/destroy)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        var create_ns: u64 = 0;
        var kill_ns: u64 = 0;
        fn create_many(h: *Ecs1.SystemHandler) anyerror!void {
            const t0 = stamp();
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
            S.create_ns = nsSince(t0);
        }
        fn check_created(h: *Ecs1.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == S.count);
            var total: usize = 0;
            for (h.allEvents(Ecs1.Create)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.count);
        }
        fn kill(h: *Ecs1.SystemHandler) anyerror!void {
            const t0 = stamp();
            try h.cmdDestroyPages(&[_]type{Pos}, null);
            S.kill_ns = nsSince(t0);
        }
    };
    S.count = @intCast(n);
    var cold_create: u64 = 0;
    var best_create: u64 = std.math.maxInt(u64);
    var cold_cframe: u64 = 0;
    var best_cframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        if (r > 0) {
            try wipeWorld(Ecs1, allocator);
        }
        const t0 = stamp();
        try Ecs1.Schedule(.{ S.create_many, S.check_created }).run(allocator);
        const dt = nsSince(t0);
        if (r == 0) {
            cold_create = S.create_ns;
            cold_cframe = dt;
        }
        best_create = @min(best_create, S.create_ns);
        best_cframe = @min(best_cframe, dt);
        // Cleanup for the next rep (untimed).
        try Ecs1.Schedule(.{S.kill}).run(allocator);
    }
    std.debug.print("S9a mass-create 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_create), ms(best_create), ms(cold_cframe), ms(best_cframe) });
    var cold_kill: u64 = 0;
    var best_kill: u64 = std.math.maxInt(u64);
    var cold_kframe: u64 = 0;
    var best_kframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        try spawn1(allocator, @intCast(n));
        const t0 = stamp();
        try Ecs1.Schedule(.{S.kill}).run(allocator);
        const dt = nsSince(t0);
        if (r == 0) {
            cold_kill = S.kill_ns;
            cold_kframe = dt;
        }
        best_kill = @min(best_kill, S.kill_ns);
        best_kframe = @min(best_kframe, dt);
    }
    std.debug.print("S9b mass-destroy 1-page N={d}: queue cold {d:.3} / best {d:.3} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_kill), ms(best_kill), ms(cold_kframe), ms(best_kframe) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S7/S8: batch set and destroy-for at max N (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1refs(allocator, @intCast(n));
    var cold_semit: u64 = 0;
    var best_semit: u64 = std.math.maxInt(u64);
    var cold_sframe: u64 = 0;
    var best_sframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchBatchSet(allocator, n);
        if (r == 0) {
            cold_semit = m.emit_ns;
            cold_sframe = m.total_ns;
        }
        best_semit = @min(best_semit, m.emit_ns);
        best_sframe = @min(best_sframe, m.total_ns);
    }
    std.debug.print("S7 batch-set 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_semit), ms(best_semit), ms(cold_sframe), ms(best_sframe) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
    var cold_wipe: u64 = 0;
    var best_wipe: u64 = std.math.maxInt(u64);
    var cold_wframe: u64 = 0;
    var best_wframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchBatchDestroy(allocator, n);
        if (r == 0) {
            cold_wipe = m.wipe_ns;
            cold_wframe = m.total_ns;
        }
        best_wipe = @min(best_wipe, m.wipe_ns);
        best_wframe = @min(best_wframe, m.total_ns);
    }
    std.debug.print("S8 batch-destroy-for 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_wipe), ms(best_wipe), ms(cold_wframe), ms(best_wframe) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S10: bulk destroy-all at max N (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1refs(allocator, @intCast(n));
    var cold_wipe: u64 = 0;
    var best_wipe: u64 = std.math.maxInt(u64);
    var cold_wframe: u64 = 0;
    var best_wframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchBulkDestroy(allocator, n);
        if (r == 0) {
            cold_wipe = m.wipe_ns;
            cold_wframe = m.total_ns;
        }
        best_wipe = @min(best_wipe, m.wipe_ns);
        best_wframe = @min(best_wframe, m.total_ns);
    }
    std.debug.print("S10 bulk-destroy-all 1-page N={d}: queue cold {d:.3} / best {d:.3} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_wipe), ms(best_wipe), ms(cold_wframe), ms(best_wframe) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S11: warmed first frame at max N (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1refs(allocator, @intCast(n));
    const handler = Ecs1.SystemHandler{ .allocator = allocator };
    try handler.setEventLimits(Damage, .{
        .slots = @intCast(n),
        .pending = @intCast(n),
        .events_per_page = @intCast(n),
        .pages = 2,
    });
    const m = try benchBatchSet(allocator, n);
    std.debug.print("S11 warmed-first-frame 1-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(m.emit_ns), ms(m.total_ns) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}
