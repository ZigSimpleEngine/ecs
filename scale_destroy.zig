const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Pos = struct { x: f32 = 0, y: f32 = 0 };

const EcsFlat = ecs_module.ECS(.{.{Pos}});

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

fn spawnFlat(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *EcsFlat.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
        }
    };
    S.count = n;
    try EcsFlat.Schedule(.{S.spawn}).run(allocator);
}

fn wipeWorld(allocator: std.mem.Allocator) !void {
    const S = struct {
        fn wipe(h: *EcsFlat.SystemHandler) anyerror!void {
            try h.cmdDestroyPages(&[_]type{Pos}, null);
        }
    };
    try EcsFlat.Schedule(.{S.wipe}).run(allocator);
}

fn entityCount(allocator: std.mem.Allocator) usize {
    const handler = EcsFlat.SystemHandler{ .allocator = allocator };
    var total: usize = 0;
    for (handler.pages(&[_]type{Pos}, null).allPages()) |p| {
        total += p.entities().len;
    }
    return total;
}

/// One frame { kill, verify }: kill loops every entity with single cmdDestroy.
/// Total covers queue + flush (per-row removeRow cascade + per-node event purge).
fn benchDestroyEach(allocator: std.mem.Allocator, want: usize) !struct { queue_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var queue_ns: u64 = 0;
        var want_count: usize = 0;
        fn kill(h: *EcsFlat.SystemHandler) anyerror!void {
            const t0 = stamp();
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdDestroy(e);
                }
            }
            S.queue_ns = nsSince(t0);
        }
        fn verify(h: *EcsFlat.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |_| {
                total += 1;
            }
            try std.testing.expect(total == 0);
            try std.testing.expect(S.want_count > 0);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try EcsFlat.Schedule(.{ S.kill, S.verify }).run(allocator);
    return .{ .queue_ns = S.queue_ns, .total_ns = nsSince(t0) };
}

test "bench S13a: destroy-each flat ladder (singles)" {
    const allocator = std.testing.allocator;
    defer EcsFlat.deinit(allocator);
    for (Ns) |n| {
        var cold_queue: u64 = 0;
        var best_queue: u64 = std.math.maxInt(u64);
        var cold_frame: u64 = 0;
        var best_frame: u64 = std.math.maxInt(u64);
        for (0..REPS) |r| {
            try spawnFlat(allocator, @intCast(n));
            try std.testing.expect(entityCount(allocator) == n);
            const m = try benchDestroyEach(allocator, n);
            if (r == 0) {
                cold_queue = m.queue_ns;
                cold_frame = m.total_ns;
            }
            best_queue = @min(best_queue, m.queue_ns);
            best_frame = @min(best_frame, m.total_ns);
            try std.testing.expect(entityCount(allocator) == 0);
        }
        std.debug.print("S13a destroy-each flat N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_queue), ms(best_queue), ms(cold_frame), ms(best_frame) });
    }
}

test "bench S13b: destroy single subtree at max N (singles)" {
    const allocator = std.testing.allocator;
    defer EcsFlat.deinit(allocator);
    const n = Ns[Ns.len - 1];
    const S = struct {
        const S = @This();
        var root: EcsFlat.EntityReference = undefined;
        var count: u32 = 0;
        fn build(h: *EcsFlat.SystemHandler) anyerror!void {
            S.root = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            _ = try h.cmdCreateChildren(S.root, &[_]type{Pos}, .{Pos{}}, S.count);
        }
        fn kill(h: *EcsFlat.SystemHandler) anyerror!void {
            try h.cmdDestroy(S.root);
        }
        fn verify(h: *EcsFlat.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |_| {
                try std.testing.expect(false);
            }
        }
    };
    S.count = @intCast(n);
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const t_build = stamp();
        try EcsFlat.Schedule(.{S.build}).run(allocator);
        const build_ms = ms(nsSince(t_build));
        try std.testing.expect(entityCount(allocator) == n + 1);
        const t0 = stamp();
        try EcsFlat.Schedule(.{ S.kill, S.verify }).run(allocator);
        const dt = nsSince(t0);
        if (r == 0) {
            cold_frame = dt;
            std.debug.print("S13b destroy-subtree N={d}: build {d:.2} ms\n", .{ n + 1, build_ms });
        }
        best_frame = @min(best_frame, dt);
        try std.testing.expect(entityCount(allocator) == 0);
    }
    std.debug.print("S13b destroy-subtree N={d}: frame cold {d:.2} / best {d:.2} ms\n", .{ n + 1, ms(cold_frame), ms(best_frame) });
}
