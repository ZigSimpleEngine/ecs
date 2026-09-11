const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Pos = struct { x: f32 = 0, y: f32 = 0 };
const Vel = struct { vx: f32 = 0, vy: f32 = 0 };

const EcsM = ecs_module.ECS(.{ .{Pos}, .{ Pos, Vel } });

const Ns: []const usize = if (builtin.mode == .Debug)
    &.{ 500, 1000, 2000 }
else
    &.{ 10000, 25000, 50000, 100000 };

const REPS: usize = if (builtin.mode == .Debug) 2 else 3;

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
fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn spawnPos(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *EcsM.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
        }
    };
    S.count = n;
    try EcsM.Schedule(.{S.spawn}).run(allocator);
}

fn wipeWorld(allocator: std.mem.Allocator) !void {
    const S = struct {
        fn wipe(h: *EcsM.SystemHandler) anyerror!void {
            // Pos is included in every archetype here: one call covers all.
            try h.cmdDestroyPages(&[_]type{Pos}, null);
        }
    };
    try EcsM.Schedule(.{S.wipe}).run(allocator);
}

fn countIn(allocator: std.mem.Allocator, comptime bundle: anytype) usize {
    const handler = EcsM.SystemHandler{ .allocator = allocator };
    var total: usize = 0;
    for (handler.pages(bundle, null).allPages()) |p| {
        total += p.entities().len;
    }
    return total;
}

/// One frame { move, verify }: every entity single cmdMigrate to dest.
/// Queue covers requireIdle+append per row; frame adds per-row
/// insertRowAtDepth cascade + copyShared + removeRow cascade + Migrate filing.
fn benchMigrate(
    allocator: std.mem.Allocator,
    comptime from: anytype,
    comptime dest: anytype,
    copy: bool,
    want: usize,
) !struct { queue_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var queue_ns: u64 = 0;
        var want_count: usize = 0;
        var do_copy: bool = true;
        fn move(h: *EcsM.SystemHandler) anyerror!void {
            const t0 = stamp();
            for (h.pages(from, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdMigrate(e, dest, S.do_copy);
                }
            }
            S.queue_ns = nsSince(t0);
        }
        fn verify(h: *EcsM.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.pages(dest, null).nonEmptyPages()) |page| {
                for (page.entities()) |_| {
                    total += 1;
                }
            }
            try std.testing.expect(total == S.want_count);
        }
    };
    S.want_count = want;
    S.do_copy = copy;
    const t0 = stamp();
    try EcsM.Schedule(.{ S.move, S.verify }).run(allocator);
    return .{ .queue_ns = S.queue_ns, .total_ns = nsSince(t0) };
}

test "bench S14a: migrate-add ladder (singles)" {
    const allocator = std.testing.allocator;
    defer EcsM.deinit(allocator);
    for (Ns) |n| {
        var cold_queue: u64 = 0;
        var best_queue: u64 = std.math.maxInt(u64);
        var cold_frame: u64 = 0;
        var best_frame: u64 = std.math.maxInt(u64);
        for (0..REPS) |r| {
            try wipeWorld(allocator);
            try spawnPos(allocator, @intCast(n));
            const m = try benchMigrate(allocator, &[_]type{Pos}, &[_]type{ Pos, Vel }, true, n);
            if (r == 0) {
                cold_queue = m.queue_ns;
                cold_frame = m.total_ns;
            }
            best_queue = @min(best_queue, m.queue_ns);
            best_frame = @min(best_frame, m.total_ns);
            try std.testing.expect(countIn(allocator, &[_]type{ Pos, Vel }) == n);
        }
        std.debug.print("S14a migrate-add N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_queue), ms(best_queue), ms(cold_frame), ms(best_frame) });
        try wipeWorld(allocator);
    }
}

test "bench S14b: migrate-remove at max N (singles)" {
    const allocator = std.testing.allocator;
    defer EcsM.deinit(allocator);
    const n = Ns[Ns.len - 1];
    // Build starting state directly in destination archetype.
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *EcsM.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{ Pos, Vel }, .{ Pos{}, Vel{} }, S.count);
        }
    };
    S.count = @intCast(n);
    var cold_queue: u64 = 0;
    var best_queue: u64 = std.math.maxInt(u64);
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        try wipeWorld(allocator);
        try EcsM.Schedule(.{S.spawn}).run(allocator);
        const m = try benchMigrate(allocator, &[_]type{ Pos, Vel }, &[_]type{Pos}, false, n);
        if (r == 0) {
            cold_queue = m.queue_ns;
            cold_frame = m.total_ns;
        }
        best_queue = @min(best_queue, m.queue_ns);
        best_frame = @min(best_frame, m.total_ns);
        try std.testing.expect(countIn(allocator, &[_]type{Pos}) == n);
    }
    std.debug.print("S14b migrate-remove N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_queue), ms(best_queue), ms(cold_frame), ms(best_frame) });
    try wipeWorld(allocator);
}

// Deep-hierarchy migrate: root + N children plus a 64-chain, all in Pos,
// migrated wholesale to Pos+Vel. Per-row zone cascades hit every member
// here, unlike the flat S14a.
test "bench S14c: migrate-add deep tree at max N (singles)" {
    const allocator = std.testing.allocator;
    defer EcsM.deinit(allocator);
    const n = Ns[Ns.len - 1];
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        var queue_ns: u64 = 0;
        var total: usize = 0;
        fn build(h: *EcsM.SystemHandler) anyerror!void {
            const root = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            _ = try h.cmdCreateChildren(root, &[_]type{Pos}, .{Pos{}}, S.count);
            var tip = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            var i: u32 = 0;
            while (i < 64) : (i += 1) {
                tip = try h.cmdCreateChild(tip, &[_]type{Pos}, .{Pos{}});
            }
        }
        fn move(h: *EcsM.SystemHandler) anyerror!void {
            const t0 = stamp();
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdMigrate(e, &[_]type{ Pos, Vel }, true);
                }
            }
            S.queue_ns = nsSince(t0);
        }
        fn verify(h: *EcsM.SystemHandler) anyerror!void {
            var n_moved: usize = 0;
            for (h.pages(&[_]type{ Pos, Vel }, null).nonEmptyPages()) |page| {
                n_moved += page.entities().len;
            }
            S.total = n_moved;
            try std.testing.expect(n_moved == S.count + 66);
        }
    };
    S.count = @intCast(n);
    var cold_queue: u64 = 0;
    var best_queue: u64 = std.math.maxInt(u64);
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        try wipeWorld(allocator);
        try EcsM.Schedule(.{S.build}).run(allocator);
        const t0 = stamp();
        try EcsM.Schedule(.{ S.move, S.verify }).run(allocator);
        const dt = nsSince(t0);
        // Queue time is measured inline; frame covers queue+flush+verify.
        if (r == 0) {
            cold_queue = S.queue_ns;
            cold_frame = dt;
        }
        best_queue = @min(best_queue, S.queue_ns);
        best_frame = @min(best_frame, dt);
        try std.testing.expect(S.total == n + 66);
    }
    std.debug.print("S14c migrate-add deep N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n + 66, ms(cold_queue), ms(best_queue), ms(cold_frame), ms(best_frame) });
    try wipeWorld(allocator);
}
