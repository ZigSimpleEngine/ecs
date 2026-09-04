const std = @import("std");
const ecs = @import("ecs");
/// Demo component holding a 2D position.
const Position = struct {
    /// Horizontal coordinate.
    x_coord: f32,
    /// Vertical coordinate.
    y_coord: f32,
};
/// Demo component holding a 2D velocity.
const Velocity = struct {
    /// Horizontal speed.
    x_speed: f32,
    /// Vertical speed.
    y_speed: f32,
};
/// Demo component holding health points.
const Health = struct {
    /// Current health amount.
    current: u32,
    /// Maximum possible health amount.
    max: u32,
};
/// Exercises every ECS public entry point and logs each result.
/// - `init` - process init info; unused.
pub fn main(init: std.process.Init) !void {
    _ = init;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.print("[deinit] allocator status: {s}\n", .{@tagName(status)});
    }
    const allocator = gpa.allocator();
    const Ecs = ecs.ECS(16, 16);
    defer Ecs.deinit(allocator);
    std.debug.print("=== 1. ECS namespace =============================\n", .{});
    std.debug.print("Created ECS(16, 16): {s}\n", .{@typeName(Ecs)});
    std.debug.print("\n=== 2. isComponent / isArchetype =================\n", .{});
    const Pos = Ecs.Component(Position);
    const Pair = Ecs.Archetype(&[_]type{ Position, Velocity });
    std.debug.print("isComponent(Component) = {}\n", .{Ecs.isComponent(Pos)});
    std.debug.print("isArchetype(Component) = {}\n", .{Ecs.isArchetype(Pos)});
    std.debug.print("isArchetype(Archetype) = {}\n", .{Ecs.isArchetype(Pair)});
    std.debug.print("isComponent(Archetype) = {}\n", .{Ecs.isComponent(Pair)});
    std.debug.print("isComponent(u32) = {} (not a struct wrapper)\n", .{Ecs.isComponent(u32)});
    std.debug.print("isArchetype(u32) = {}\n", .{Ecs.isArchetype(u32)});
    std.debug.print("\n=== 3. Component ids =============================\n", .{});
    const Vel = Ecs.Component(Velocity);
    const Hp = Ecs.Component(Health);
    std.debug.print("Pos.id() = {d}\n", .{Pos.id()});
    std.debug.print("Pos.id() again = {d} (stable)\n", .{Ecs.Component(Position).id()});
    std.debug.print("Vel.id() = {d}, Hp.id() = {d}\n", .{ Vel.id(), Hp.id() });
    const pos_info = Pos.info();
    std.debug.print("info(Pos): id={d} size={d} align={d} name={s}\n", .{
        pos_info.id,
        pos_info.size,
        pos_info.alignment,
        pos_info.name,
    });
    std.debug.print("info(Hp): id={d} size={d} name={s}\n", .{
        Hp.info().id,
        Hp.info().size,
        Hp.info().name,
    });
    std.debug.print("\n=== 4. GetComponentsTypes / CreateArchetype ======\n", .{});
    const normalized = Ecs.GetComponentsTypes(&[_]type{
        Vel,
        Position,
        Pair,
    });
    std.debug.print("normalized count = {d} (dedup + flatten)\n", .{normalized.len});
    const Direct = Ecs.CreateArchetype(&[_]type{Position});
    std.debug.print("CreateArchetype([Pos]) == Archetype([Pos]): {}\n", .{
        Direct == Ecs.Archetype(&[_]type{Position}),
    });
    std.debug.print("Direct.id() = {d}\n", .{Direct.id()});
    std.debug.print("\n=== 5. Archetype order / add / remove ===========\n", .{});
    const Reordered = Ecs.Archetype(&[_]type{ Velocity, Position });
    std.debug.print("[Pos,Vel] == [Vel,Pos]: {}\n", .{Pair == Reordered});
    std.debug.print("Pair.id() = {d}\n", .{Pair.id()});
    const Small = Ecs.Archetype(&[_]type{Position});
    const Grown = Small.add(Velocity);
    std.debug.print("Small.add(Vel) == Pair: {}\n", .{Grown == Pair});
    const Shrunk = Grown.remove(Vel);
    std.debug.print("Grown.remove(Vel) == Small: {}\n", .{Shrunk == Small});
    const Full = Ecs.Archetype(&[_]type{ Position, Velocity, Health });
    const MultiWide = Small.addMany(&[_]type{ Hp, Velocity });
    std.debug.print("Small.addMany([Hp, Vel]) == Full: {}\n", .{MultiWide == Full});
    const MultiSlim = Full.removeMany(&[_]type{ Velocity, Health });
    std.debug.print("Full.removeMany([Vel, Hp]) == Small: {}\n", .{MultiSlim == Small});
    std.debug.print("\n=== 6. register / ArchetypeInfo ==================\n", .{});
    const small_info = try Small.register(allocator);
    const pair_info = try Pair.register(allocator);
    const full_info = try Full.register(allocator);
    std.debug.print("ids: Small={d} Pair={d} Full={d}\n", .{
        small_info.id,
        pair_info.id,
        full_info.id,
    });
    std.debug.print("Full.components = {d}\n", .{full_info.components.len});
    for (full_info.components, 0..) |meta, order| {
        std.debug.print("  [{d}]: id={d} name={s}\n", .{ order, meta.id, meta.name });
    }
    std.debug.print("Small.supersets = {d}, Pair.supersets = {d}, Full.supersets = {d}\n", .{
        small_info.supersets().count(),
        pair_info.supersets().count(),
        full_info.supersets().count(),
    });
    std.debug.print("Pair.has(Pos) = {}, Pair.has(Hp) = {}\n", .{
        pair_info.has(pos_info),
        pair_info.has(Hp.info()),
    });
    std.debug.print("Pos.archetypes = {d}\n", .{pos_info.archetypes().count()});
    std.debug.print("\n=== 7. Entity.create / get =======================\n", .{});
    const first = try Ecs.Entity.create(allocator, pair_info);
    std.debug.print("created: id={d} gen={d} index={d}\n", .{
        first.reference.id,
        first.reference.gen,
        first.index,
    });
    std.debug.print("Pair.count() = {d}\n", .{pair_info.count()});
    const pair_data = Pair.data();
    const pos_slot: *Position = try pair_data.getMut(Position, first.index);
    pos_slot.x_coord = 10.0;
    pos_slot.y_coord = 20.0;
    const vel_slot: *Velocity = try pair_data.getMut(Velocity, first.index);
    vel_slot.x_speed = 1.5;
    vel_slot.y_speed = -2.5;
    std.debug.print("wrote Pos(10, 20) Vel(1.5, -2.5)\n", .{});
    const check: *const Position = try pair_data.get(Position, first.index);
    std.debug.print("read Pos: x={d} y={d}\n", .{ check.x_coord, check.y_coord });
    std.debug.print("list(Pos).count() = {d}, entities().count() = {d}\n", .{
        pair_data.list(Position).count(),
        pair_data.entities().count(),
    });
    std.debug.print("\n=== 8. ReadOnlyList ==============================\n", .{});
    const exposed = pair_data.entities();
    std.debug.print("count = {d}\n", .{exposed.count()});
    for (exposed.items(), 0..) |listed, at| {
        std.debug.print("  [{d}]: id={d} gen={d}\n", .{ at, listed.id, listed.gen });
    }
    std.debug.print("get(0) hit = {}, get(99) hit = {}\n", .{ exposed.get(0) != null, exposed.get(99) != null });
    std.debug.print("contains(first) = {}\n", .{exposed.contains(first.reference)});
    const fake = Ecs.EntityReference{ .id = 250, .gen = 0 };
    std.debug.print("contains(fake) = {}\n", .{exposed.contains(fake)});
    std.debug.print("\n=== 9. raw / rawMut / rawList ====================\n", .{});
    const raw_bytes: ?[]const u8 = pair_data.raw(pos_info, 0);
    if (raw_bytes) |found| {
        std.debug.print("raw(Pos, 0): {d} bytes (sizeOf={d})\n", .{ found.len, @sizeOf(Position) });
        const decoded: *const Position = @ptrCast(@alignCast(found.ptr));
        std.debug.print("  decoded: x={d} y={d}\n", .{ decoded.x_coord, decoded.y_coord });
    } else {
        std.debug.print("raw returned null (unexpected!)\n", .{});
    }
    const absent: ?[]const u8 = pair_data.raw(Hp.info(), 0);
    std.debug.print("raw(Hp) on Pair is null: {}\n", .{absent == null});
    const mutable: ?[]u8 = pair_data.rawMut(pos_info, 0);
    if (mutable) |writable| {
        const target: *Position = @ptrCast(@alignCast(writable.ptr));
        target.x_coord = 99.0;
        std.debug.print("rawMut: set x=99 through raw bytes\n", .{});
    }
    const recheck: *const Position = try pair_data.get(Position, 0);
    std.debug.print("recheck x={d} (expect 99)\n", .{recheck.x_coord});
    const bulk: ?[]const u8 = pair_data.rawList(pos_info);
    if (bulk) |whole| {
        std.debug.print("rawList: {d} bytes for {d} item(s)\n", .{ whole.len, pair_data.list(Position).count() });
    }
    std.debug.print("\n=== 10. Reference queries ========================\n", .{});
    std.debug.print("first exists = {}, alive = {}\n", .{ first.reference.exists(), first.reference.isAlive() });
    if (first.reference.entity()) |fetched| {
        std.debug.print("entity(): id={d} index={d}\n", .{ fetched.reference.id, fetched.index });
    }
    const stored: Ecs.EntityReference = try pair_data.entity(first.index);
    std.debug.print("data.entity(0): id={d} gen={d}\n", .{ stored.id, stored.gen });
    std.debug.print("exists(0) = {}, exists(99) = {}\n", .{ pair_data.exists(0), pair_data.exists(99) });
    std.debug.print("\n=== 11. info.add / info.remove ===================\n", .{});
    const Scratch = Ecs.Archetype(&[_]type{Health});
    const scratch_info = try Scratch.register(allocator);
    const probe_a = Ecs.EntityReference{ .id = 100, .gen = 1 };
    const probe_b = Ecs.EntityReference{ .id = 101, .gen = 2 };
    const index_a: u32 = try scratch_info.add(allocator, &probe_a);
    const index_b: u32 = try scratch_info.add(allocator, &probe_b);
    std.debug.print("added at {d} and {d}, count={d}\n", .{ index_a, index_b, scratch_info.count() });
    const moved: ?Ecs.EntityReference = scratch_info.remove(index_a);
    std.debug.print("remove(0): count={d}, displaced present={}\n", .{ scratch_info.count(), moved != null });
    if (moved) |relocated| {
        std.debug.print("  displaced: id={d} gen={d}\n", .{ relocated.id, relocated.gen });
    }
    std.debug.print("\n=== 12. migrate ==================================\n", .{});
    const migrated = try first.reference.migrate(allocator, full_info, true);
    std.debug.print("migrated: id={d} gen {d} -> {d}\n", .{
        migrated.id,
        first.reference.gen,
        migrated.gen,
    });
    std.debug.print("old alive = {} (false), new alive = {} (true)\n", .{
        first.reference.isAlive(),
        migrated.isAlive(),
    });
    std.debug.print("Pair={d}, Full={d}\n", .{ pair_info.count(), full_info.count() });
    const full_data = Full.data();
    const migrated_pos: *const Position = try full_data.get(Position, 0);
    std.debug.print("copied Pos in Full: x={d} y={d} (expect 99, 20)\n", .{ migrated_pos.x_coord, migrated_pos.y_coord });
    const second = try migrated.migrate(allocator, small_info, false);
    std.debug.print("Full -> Small without copy: gen={d}\n", .{second.gen});
    std.debug.print("Full={d}, Small={d}\n", .{ full_info.count(), small_info.count() });
    std.debug.print("\n=== 13. destroy / reuse ==========================\n", .{});
    try second.destroy(allocator);
    std.debug.print("destroyed: alive={} (false), exists={} (true)\n", .{ second.isAlive(), second.exists() });
    second.destroy(allocator) catch |err| {
        std.debug.print("double destroy (expected): {s}\n", .{@errorName(err)});
    };
    const reused = try Ecs.Entity.create(allocator, small_info);
    std.debug.print("reused slot: id={d} (same), gen={d} (bumped)\n", .{
        reused.reference.id,
        reused.reference.gen,
    });
    std.debug.print("reused alive = {}\n", .{reused.reference.isAlive()});
    std.debug.print("\n=== DONE =========================================\n", .{});
}
