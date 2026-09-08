const std = @import("std");
/// Builds a read-only view over a standard unmanaged array list.
/// - `Element` - element type stored in the wrapped list.
///
/// Returns `type` - view type exposing only read access to the list.
pub fn ReadOnlyList(comptime Element: type) type {
    return struct {
        const Self = @This();
        /// Pointer to the wrapped list. Reads always observe live data.
        source: *const std.ArrayListUnmanaged(Element),
        /// Wraps an existing list without copying it.
        /// - `source` - list to observe.
        ///
        /// Returns `Self` - read-only view bound to the given list.
        pub fn init(source: *const std.ArrayListUnmanaged(Element)) Self {
            return Self{
                .source = source,
            };
        }
        /// Counts stored elements.
        /// - `self` - view to inspect.
        ///
        /// Returns `usize` - current element count.
        pub fn count(self: *const Self) usize {
            return self.source.items.len;
        }
        /// Exposes the whole backing slice for iteration.
        /// - `self` - view to inspect.
        ///
        /// Returns `[]const Element` - read-only slice of all elements.
        pub fn items(self: *const Self) []const Element {
            return self.source.items;
        }
        /// Fetches a single element by position.
        /// - `self` - view to inspect.
        /// - `index` - element position.
        ///
        /// Returns `?Element` - stored value, or null when out of bounds.
        pub fn get(self: *const Self, index: usize) ?Element {
            if (index >= self.source.items.len) {
                return null;
            }
            return self.source.items[index];
        }
        /// Checks whether a value is stored in the list.
        /// - `self` - view to inspect.
        /// - `target` - value to search for.
        ///
        /// Returns `bool` - true when an equal element exists.
        pub fn contains(self: *const Self, target: Element) bool {
            for (self.source.items) |current| {
                if (current == target) {
                    return true;
                }
            }
            return false;
        }
    };
}
/// Builds a fully static Entity Component System from a closed archetype set.
/// - `sets` - tuple of component bundles, one bundle per archetype. A bundle is
///   a tuple of component struct types, possibly nested: only tuples are
///   traversed recursively, named structs are treated as leaf components.
///   Duplicate components inside one archetype and duplicate archetypes are
///   removed in comptime. Component order does not matter.
///
/// Example: `const Transform = .{ Pos, Vel };` then
/// `const Ecs = ECS(.{ Transform, .{ Transform, Health } });`.
///
/// All metadata (`components`, `archetypes`, per-component archetype lists and
/// per-archetype superset lists) is precomputed once in comptime and immutable.
/// There is no dynamic component or archetype registration. Ids are dense table
/// indices: component id = index into `components` (sorted by type name),
/// archetype id = index into `archetypes` (first-seen input order).
///
/// Example: `const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });`
///
/// Returns `type` - ECS namespace with static metadata and runtime entity storage.
pub fn ECS(comptime sets: anytype) type {
    return struct {
        const Ecs = @This();
        /// Failure modes of ECS operations, including allocator failures.
        pub const EcsError = std.mem.Allocator.Error || error{
            /// Operation requires a live entity but the reference is stale.
            EntityIsNotAlive,
            /// Entity already has a queued destroy or migrate in this batch.
            EntityHasPendingCommand,
            /// Requested position lies outside the storage range.
            IndexOutOfBounds,
            /// Requested component is not stored in this archetype.
            ComponentNotFoundInArchetype,
        };
        /// Deferred lifecycle state of an entity slot: none, queued for
        /// destroy, or queued for migrate. Densely packed, 2 bits per slot,
        /// 4 slots per byte in `entity_state_words`, so one byte answers
        /// four slots at once.
        pub const EntityState = enum(u2) {
            none = 0,
            pending_destroy = 1,
            pending_migrate = 2,
        };
        /// Lightweight entity handle. Stays small enough to copy by value.
        /// The id is the slot index into the SoA columns below, so no
        /// separate `Entity` struct is stored: generation, archetype, row
        /// and pending state are parallel arrays indexed by id.
        pub const EntityReference = packed struct {
            /// Entity slot id. Matches the position in the SoA columns.
            id: u24,
            /// Slot generation. Bumped on every destroy and migrate.
            gen: u8,
            /// Checks whether this id was ever assigned to an entity.
            /// - `self` - reference to inspect.
            ///
            /// Returns `bool` - true when a record slot exists for the id.
            pub fn exists(self: *const EntityReference) bool {
                const entity_index: u32 = self.id;
                return entity_index < Ecs.entity_generation.items.len;
            }
            /// Checks whether the reference still points at a live entity.
            /// - `self` - reference to inspect.
            ///
            /// Returns `bool` - true when the slot exists and generations match.
            pub fn isAlive(self: *const EntityReference) bool {
                if (!self.exists()) {
                    return false;
                }
                const entity_index: u32 = self.id;
                return Ecs.entity_generation.items[entity_index] == self.gen;
            }
            /// Returns the pending lifecycle state of the referenced slot.
            /// - `self` - reference to inspect.
            ///
            /// Returns `EntityState` - queued state, or `none` when the id
            /// was never assigned (treated as idle, not pending).
            pub fn state(self: *const EntityReference) EntityState {
                const entity_index: u32 = self.id;
                if (entity_index >= Ecs.entityStateLen()) {
                    return .none;
                }
                return Ecs.getEntityState(entity_index);
            }
            /// Loads a fresh handle for the same id behind this reference.
            /// Useful to refresh a stale copy after a migrate.
            /// - `self` - reference to resolve.
            ///
            /// Returns `?EntityReference` - live handle, or null when not alive.
            pub fn entity(self: *const EntityReference) ?EntityReference {
                if (!self.isAlive()) {
                    return null;
                }
                return self.*;
            }
            /// Returns the archetype currently owning the entity.
            /// - `self` - reference to resolve. Must be alive.
            pub fn archetypeOf(self: *const EntityReference) EcsError!u32 {
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                return Ecs.entity_archetype.items[entity_index];
            }
            /// Returns the row position inside the owning archetype storage.
            /// - `self` - reference to resolve. Must be alive.
            pub fn indexOf(self: *const EntityReference) EcsError!u32 {
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                return Ecs.entity_row.items[entity_index];
            }
            /// Destroys the referenced entity and recycles its slot.
            /// Immediate variant used by command flushing. Clears any pending
            /// state left by the queueing command.
            /// - `self` - reference to destroy. Must be alive.
            /// - `allocator` - funds the free-slot bookkeeping.
            fn destroy(self: *const EntityReference, allocator: std.mem.Allocator) EcsError!void {
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                const arch: u32 = Ecs.entity_archetype.items[entity_index];
                const index: u32 = Ecs.entity_row.items[entity_index];
                const displaced: ?EntityReference = blk: {
                    inline for (0..ARCH_COUNT) |k| {
                        if (arch == k) {
                            break :blk Ecs.storages[k].remove(index);
                        }
                    }
                    unreachable;
                };
                if (displaced) |relocated| {
                    const relocated_index: u32 = relocated.id;
                    Ecs.entity_row.items[relocated_index] = index;
                }
                Ecs.entity_generation.items[entity_index] +%= 1;
                Ecs.setEntityState(entity_index, .none);
                try Ecs.free_ids.append(allocator, entity_index);
            }
            /// Moves the entity into another archetype, optionally copying shared data.
            /// - `self` - reference to move. Must be alive.
            /// - `allocator` - funds the destination slot.
            /// - `dest` - component bundle of the destination archetype. Must be declared in `ECS(...)`.
            /// - `copy` - when true, shared component values are carried over.
            ///
            /// Returns `EntityReference` - refreshed handle with a bumped generation.
            /// Private: structural changes run only via commands flushed by the scheduler.
            fn migrate(
                self: *const EntityReference,
                allocator: std.mem.Allocator,
                comptime dest: anytype,
                copy: bool,
            ) EcsError!EntityReference {
                const dest_id = comptime Ecs.archetypeId(dest);
                return self.migrateById(allocator, dest_id, copy);
            }
            /// Moves the entity into the archetype with the given id.
            /// - `self` - reference to move. Must be alive.
            /// - `allocator` - funds the destination slot.
            /// - `dest_id` - destination archetype id, an index into `archetypes`.
            /// - `copy` - when true, shared component values are carried over.
            ///
            /// Returns `EntityReference` - refreshed handle with a bumped generation.
            /// Private: structural changes run only via commands flushed by the scheduler.
            fn migrateById(
                self: *const EntityReference,
                allocator: std.mem.Allocator,
                dest_id: u32,
                copy: bool,
            ) EcsError!EntityReference {
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                const source_id: u32 = Ecs.entity_archetype.items[entity_index];
                const source_index: u32 = Ecs.entity_row.items[entity_index];
                const next = EntityReference{
                    .id = self.id,
                    .gen = self.gen +% 1,
                };
                const dest_index: u32 = blk: {
                    inline for (0..ARCH_COUNT) |k| {
                        if (dest_id == k) {
                            break :blk try Ecs.storages[k].add(allocator, &next);
                        }
                    }
                    unreachable;
                };
                if (copy) {
                    Ecs.copyShared(
                        source_id,
                        source_index,
                        dest_id,
                        dest_index,
                    );
                }
                const displaced: ?EntityReference = blk: {
                    inline for (0..ARCH_COUNT) |k| {
                        if (source_id == k) {
                            break :blk Ecs.storages[k].remove(source_index);
                        }
                    }
                    unreachable;
                };
                if (displaced) |relocated| {
                    const relocated_index: u32 = relocated.id;
                    Ecs.entity_row.items[relocated_index] = source_index;
                }
                Ecs.entity_generation.items[entity_index] = next.gen;
                Ecs.entity_archetype.items[entity_index] = dest_id;
                Ecs.entity_row.items[entity_index] = dest_index;
                Ecs.setEntityState(entity_index, .none);
                return next;
            }
        };
        /// Static descriptor of a single component type. Immutable, built once in comptime.
        pub const ComponentInfo = struct {
            /// Dense component id. Always equals the index into `components`.
            id: u32,
            /// Byte size of one component value.
            size: usize,
            /// Byte alignment of the component type.
            alignment: usize,
            /// Fully qualified component type name.
            name: []const u8,
            /// Ids of every archetype containing this component.
            archetype_ids: []const u32,
        };
        /// Static descriptor of a single archetype. Immutable, built once in comptime.
        /// `component_ids` is sorted ascending and also defines the column order.
        pub const ArchetypeInfo = struct {
            /// Dense archetype id. Always equals the index into `archetypes`.
            id: u32,
            /// Sorted ids of the stored component types.
            component_ids: []const u32,
            /// Ids of archetypes strictly containing this one. Precomputed in comptime.
            superset_ids: []const u32,
        };
        /// Number of input archetype tuples. Validated to be a tuple below.
        const input_count: usize = blk: {
            const info = @typeInfo(@TypeOf(sets));
            if (info != .@"struct" or !info.@"struct".is_tuple) {
                @compileError("ECS expects a tuple of archetype tuples, e.g. ECS(.{ .{Pos, Vel}, .{Pos} }).");
            }
            break :blk info.@"struct".fields.len;
        };
        /// Largest leaf count over all archetype bundles. Statically frozen so it
        /// can size comptime buffers. Nested tuples are counted recursively.
        const max_len: usize = blk: {
            if (input_count == 0) {
                @compileError("ECS needs at least one archetype.");
            }
            var biggest: usize = 0;
            for (0..input_count) |i| {
                const inner_info = @typeInfo(@TypeOf(sets[i]));
                if (inner_info != .@"struct" or !inner_info.@"struct".is_tuple) {
                    @compileError("Each archetype must be a tuple of component types; tuples may be nested.");
                }
                const leaf_count = flattenTypes(sets[i]).len;
                if (leaf_count > biggest) {
                    biggest = leaf_count;
                }
            }
            const Keep = struct {
                const value: usize = biggest;
            };
            break :blk Keep.value;
        };
        /// Every comptime table: canonical types, deduplicated archetypes, components,
        /// superset links and component->archetype links. Frozen once, read-only after.
        const Tables = blk: {
            var canon_types: [input_count][max_len]type = undefined;
            var canon_lens: [input_count]usize = [_]usize{0} ** input_count;
            for (0..input_count) |i| {
                const flat = flattenTypes(sets[i]);
                var uniq: [max_len]type = undefined;
                var total: usize = 0;
                for (flat) |candidate| {
                    var duplicate: bool = false;
                    for (uniq[0..total]) |existing| {
                        if (existing == candidate) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        uniq[total] = candidate;
                        total += 1;
                    }
                }
                var outer: usize = 0;
                while (outer < total) : (outer += 1) {
                    var inner_cursor: usize = outer + 1;
                    while (inner_cursor < total) : (inner_cursor += 1) {
                        const left: []const u8 = @typeName(uniq[outer]);
                        const right: []const u8 = @typeName(uniq[inner_cursor]);
                        if (std.mem.order(u8, right, left) == .lt) {
                            const swap: type = uniq[outer];
                            uniq[outer] = uniq[inner_cursor];
                            uniq[inner_cursor] = swap;
                        }
                    }
                }
                canon_types[i] = uniq;
                canon_lens[i] = total;
            }
            var arch_types: [input_count][max_len]type = undefined;
            var arch_lens: [input_count]usize = [_]usize{0} ** input_count;
            var uniq_count: usize = 0;
            for (0..input_count) |i| {
                var duplicate: bool = false;
                for (0..uniq_count) |u| {
                    if (canon_lens[i] != arch_lens[u]) {
                        continue;
                    }
                    var same: bool = true;
                    for (0..canon_lens[i]) |k| {
                        if (canon_types[i][k] != arch_types[u][k]) {
                            same = false;
                            break;
                        }
                    }
                    if (same) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    arch_types[uniq_count] = canon_types[i];
                    arch_lens[uniq_count] = canon_lens[i];
                    uniq_count += 1;
                }
            }
            var comp_types: [input_count * max_len]type = undefined;
            var comp_count: usize = 0;
            for (0..uniq_count) |a| {
                for (0..arch_lens[a]) |k| {
                    const T: type = arch_types[a][k];
                    var seen: bool = false;
                    for (0..comp_count) |c| {
                        if (comp_types[c] == T) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) {
                        comp_types[comp_count] = T;
                        comp_count += 1;
                    }
                }
            }
            var comp_outer: usize = 0;
            while (comp_outer < comp_count) : (comp_outer += 1) {
                var comp_inner: usize = comp_outer + 1;
                while (comp_inner < comp_count) : (comp_inner += 1) {
                    const left: []const u8 = @typeName(comp_types[comp_outer]);
                    const right: []const u8 = @typeName(comp_types[comp_inner]);
                    if (std.mem.order(u8, right, left) == .lt) {
                        const swap: type = comp_types[comp_outer];
                        comp_types[comp_outer] = comp_types[comp_inner];
                        comp_types[comp_inner] = swap;
                    }
                }
            }
            var arch_comp: [input_count][max_len]u32 = undefined;
            for (0..uniq_count) |a| {
                for (0..arch_lens[a]) |k| {
                    var found: ?usize = null;
                    for (0..comp_count) |c| {
                        if (comp_types[c] == arch_types[a][k]) {
                            found = c;
                            break;
                        }
                    }
                    arch_comp[a][k] = @intCast(found.?);
                }
            }
            var sup: [input_count][input_count]u32 = undefined;
            var sup_lens: [input_count]usize = [_]usize{0} ** input_count;
            var total_sup: usize = 0;
            for (0..uniq_count) |a| {
                var n: usize = 0;
                for (0..uniq_count) |b| {
                    if (a == b) {
                        continue;
                    }
                    if (arch_lens[b] <= arch_lens[a]) {
                        continue;
                    }
                    var covers: bool = true;
                    for (0..arch_lens[a]) |k| {
                        var has: bool = false;
                        for (0..arch_lens[b]) |j| {
                            if (arch_comp[b][j] == arch_comp[a][k]) {
                                has = true;
                                break;
                            }
                        }
                        if (!has) {
                            covers = false;
                            break;
                        }
                    }
                    if (covers) {
                        sup[a][n] = @intCast(b);
                        n += 1;
                    }
                }
                sup_lens[a] = n;
                total_sup += n;
            }
            var ca: [input_count * max_len][input_count]u32 = undefined;
            var ca_lens: [input_count * max_len]usize = [_]usize{0} ** (input_count * max_len);
            var total_ca: usize = 0;
            for (0..comp_count) |c| {
                var n: usize = 0;
                for (0..uniq_count) |a| {
                    var has: bool = false;
                    for (0..arch_lens[a]) |k| {
                        if (arch_comp[a][k] == @as(u32, @intCast(c))) {
                            has = true;
                            break;
                        }
                    }
                    if (has) {
                        ca[c][n] = @intCast(a);
                        n += 1;
                    }
                }
                ca_lens[c] = n;
                total_ca += n;
            }
            var total_arch_entries: usize = 0;
            for (0..uniq_count) |a| {
                total_arch_entries += arch_lens[a];
            }
            break :blk .{
                .uniq_count = uniq_count,
                .comp_count = comp_count,
                .arch_types = arch_types,
                .arch_comp = arch_comp,
                .arch_lens = arch_lens,
                .sup = sup,
                .sup_lens = sup_lens,
                .ca = ca,
                .ca_lens = ca_lens,
                .comp_types = comp_types,
                .total_arch_entries = total_arch_entries,
                .total_sup = total_sup,
                .total_ca = total_ca,
            };
        };
        /// Number of unique archetypes. Ids are `0..archetype_count-1`.
        pub const archetype_count: usize = Tables.uniq_count;
        /// Number of unique components. Ids are `0..component_count-1`.
        pub const component_count: usize = Tables.comp_count;
        /// Alias used by dispatch loops.
        const ARCH_COUNT: usize = Tables.uniq_count;
        /// Flat component ids of every archetype, concatenated in archetype order.
        const arch_comp_flat: [Tables.total_arch_entries]u32 = blk: {
            var flat: [Tables.total_arch_entries]u32 = undefined;
            var cursor: usize = 0;
            for (0..ARCH_COUNT) |a| {
                for (0..Tables.arch_lens[a]) |k| {
                    flat[cursor] = Tables.arch_comp[a][k];
                    cursor += 1;
                }
            }
            break :blk flat;
        };
        /// Flat superset ids of every archetype, concatenated in archetype order.
        const arch_sup_flat: [Tables.total_sup]u32 = blk: {
            var flat: [Tables.total_sup]u32 = undefined;
            var cursor: usize = 0;
            for (0..ARCH_COUNT) |a| {
                for (0..Tables.sup_lens[a]) |k| {
                    flat[cursor] = Tables.sup[a][k];
                    cursor += 1;
                }
            }
            break :blk flat;
        };
        /// Flat archetype ids of every component, concatenated in component order.
        const comp_arch_flat: [Tables.total_ca]u32 = blk: {
            var flat: [Tables.total_ca]u32 = undefined;
            var cursor: usize = 0;
            for (0..component_count) |c| {
                for (0..Tables.ca_lens[c]) |k| {
                    flat[cursor] = Tables.ca[c][k];
                    cursor += 1;
                }
            }
            break :blk flat;
        };
        /// Static component descriptors. `components[id].id == id` always holds.
        pub const components: [component_count]ComponentInfo = blk: {
            var out: [component_count]ComponentInfo = undefined;
            var cursor: usize = 0;
            for (0..component_count) |c| {
                const T: type = Tables.comp_types[c];
                const len: usize = Tables.ca_lens[c];
                out[c] = ComponentInfo{
                    .id = @intCast(c),
                    .size = @sizeOf(T),
                    .alignment = @alignOf(T),
                    .name = @typeName(T),
                    .archetype_ids = comp_arch_flat[cursor..][0..len],
                };
                cursor += len;
            }
            break :blk out;
        };
        /// Static archetype descriptors. `archetypes[id].id == id` always holds.
        pub const archetypes: [archetype_count]ArchetypeInfo = blk: {
            var out: [archetype_count]ArchetypeInfo = undefined;
            var comp_cursor: usize = 0;
            var sup_cursor: usize = 0;
            for (0..archetype_count) |a| {
                const comp_len: usize = Tables.arch_lens[a];
                const sup_len: usize = Tables.sup_lens[a];
                out[a] = ArchetypeInfo{
                    .id = @intCast(a),
                    .component_ids = arch_comp_flat[comp_cursor..][0..comp_len],
                    .superset_ids = arch_sup_flat[sup_cursor..][0..sup_len],
                };
                comp_cursor += comp_len;
                sup_cursor += sup_len;
            }
            break :blk out;
        };
        /// Checks whether a comptime type list contains a type.
        /// - `list` - types to search.
        /// - `Item` - type to look up.
        ///
        /// Returns `bool` - true when an equal type is present.
        fn hasType(comptime list: []const type, comptime Item: type) bool {
            for (list) |T| {
                if (T == Item) {
                    return true;
                }
            }
            return false;
        }
        /// Maps a type to its column index inside a comptime type list.
        /// - `list` - types defining the column order.
        /// - `Item` - type to locate. Must be present.
        ///
        /// Returns `usize` - column index of the type.
        fn indexOfType(comptime list: []const type, comptime Item: type) usize {
            for (list, 0..) |T, i| {
                if (T == Item) {
                    return i;
                }
            }
            @compileError("Type is not part of this archetype.");
        }
        /// Finds the component id of a type. Works at comptime and runtime.
        /// - `T` - component type to look up.
        ///
        /// Returns `?usize` - component id, or null when the type was never declared.
        fn componentIndex(comptime T: type) ?usize {
            for (0..component_count) |c| {
                if (Tables.comp_types[c] == T) {
                    return c;
                }
            }
            return null;
        }
        /// Counts leaf component types inside a possibly nested bundle.
        /// Only tuples and arrays are traversed; named structs count as one leaf.
        /// - `node` - a type, a tuple/array of types, or a pointer to either.
        ///
        /// Returns `usize` - number of leaf entries in the bundle.
        fn countLeafTypes(comptime node: anytype) usize {
            const Info = @typeInfo(@TypeOf(node));
            if (Info == .pointer and Info.pointer.size == .slice) {
                var total: usize = 0;
                for (0..node.len) |i| {
                    total += countLeafTypes(node[i]);
                }
                return total;
            }
            if (Info == .pointer) {
                return countLeafTypes(node.*);
            }
            if (Info == .@"struct" and Info.@"struct".is_tuple) {
                var total: usize = 0;
                for (0..Info.@"struct".fields.len) |i| {
                    total += countLeafTypes(node[i]);
                }
                return total;
            }
            if (Info == .array) {
                var total: usize = 0;
                for (0..Info.array.len) |i| {
                    total += countLeafTypes(node[i]);
                }
                return total;
            }
            return 1;
        }
        /// Collects leaf component types from a possibly nested bundle.
        /// Only tuples and arrays are traversed; named structs are leaves.
        /// - `node` - a type, a tuple/array of types, or a pointer to either.
        /// - `buf` - backing storage for the collected types.
        /// - `start` - position in `buf` where collection begins.
        ///
        /// Returns `usize` - position in `buf` just past the collected types.
        fn collectLeafTypes(comptime node: anytype, buf: []type, start: usize) usize {
            const Info = @typeInfo(@TypeOf(node));
            if (Info == .pointer and Info.pointer.size == .slice) {
                var cursor: usize = start;
                for (0..node.len) |i| {
                    cursor = collectLeafTypes(node[i], buf, cursor);
                }
                return cursor;
            }
            if (Info == .pointer) {
                return collectLeafTypes(node.*, buf, start);
            }
            if (Info == .@"struct" and Info.@"struct".is_tuple) {
                var cursor: usize = start;
                for (0..Info.@"struct".fields.len) |i| {
                    cursor = collectLeafTypes(node[i], buf, cursor);
                }
                return cursor;
            }
            if (Info == .array) {
                var cursor: usize = start;
                for (0..Info.array.len) |i| {
                    cursor = collectLeafTypes(node[i], buf, cursor);
                }
                return cursor;
            }
            if (@TypeOf(node) != type) {
                @compileError("Every entry must be a component type or a tuple of component types.");
            }
            const T: type = node;
            if (@typeInfo(T) != .@"struct") {
                @compileError("Every component must be a struct type.");
            }
            if (T == EntityReference) {
                @compileError("EntityReference cannot be a component.");
            }
            buf[start] = T;
            return start + 1;
        }
        /// Flattens a possibly nested component bundle into a plain type list.
        /// Accepts single types, tuples of types nested arbitrarily, arrays and
        /// pointers to either (as produced by `&.{...}`).
        /// - `input` - component bundle to flatten.
        ///
        /// Returns `[]const type` - flat type list, order preserved, duplicates kept.
        fn flattenTypes(comptime input: anytype) []const type {
            return flattenTypesInner(input, false);
        }
        /// Flattens a bundle like `flattenTypes`, but an empty bundle is allowed
        /// and yields an empty list instead of a compile error.
        /// - `input` - component bundle to flatten.
        ///
        /// Returns `[]const type` - flat type list, possibly empty.
        fn flattenTypesAllowEmpty(comptime input: anytype) []const type {
            return flattenTypesInner(input, true);
        }
        /// Shared implementation of `flattenTypes` and `flattenTypesAllowEmpty`.
        /// - `input` - component bundle to flatten.
        /// - `allow_empty` - when false, an empty bundle is a compile error.
        ///
        /// Returns `[]const type` - flat type list, order preserved, duplicates kept.
        fn flattenTypesInner(comptime input: anytype, comptime allow_empty: bool) []const type {
            const total = blk: {
                const n = countLeafTypes(input);
                const Keep = struct {
                    const value: usize = n;
                };
                break :blk Keep.value;
            };
            if (total == 0 and !allow_empty) {
                @compileError("Archetype or query must contain at least one component type.");
            }
            return comptime flat: {
                var buf: [total]type = undefined;
                const end = collectLeafTypes(input, buf[0..], 0);
                const Keep = struct {
                    const values: [total]type = buf;
                    const count: usize = end;
                };
                break :flat Keep.values[0..Keep.count];
            };
        }
        /// Canonicalizes a component bundle: flattens nested tuples, dedups
        /// and sorts by type name.
        /// - `input` - component bundle: types, tuples, arrays or pointers to either.
        ///
        /// Returns `[]const type` - canonical, sorted, unique type list.
        fn canonicalQuery(comptime input: anytype) []const type {
            return canonicalQueryInner(input, false);
        }
        /// Canonicalizes a bundle like `canonicalQuery`, but an empty bundle is
        /// allowed and yields an empty list instead of a compile error.
        /// - `input` - component bundle to canonicalize.
        ///
        /// Returns `[]const type` - canonical list, possibly empty.
        fn canonicalQueryAllowEmpty(comptime input: anytype) []const type {
            return canonicalQueryInner(input, true);
        }
        /// Shared implementation of `canonicalQuery` and `canonicalQueryAllowEmpty`.
        /// - `input` - component bundle to canonicalize.
        /// - `allow_empty` - when false, an empty bundle is a compile error.
        ///
        /// Returns `[]const type` - canonical, sorted, unique type list.
        fn canonicalQueryInner(comptime input: anytype, comptime allow_empty: bool) []const type {
            return comptime canon: {
                const flat_input = if (allow_empty)
                    flattenTypesAllowEmpty(input)
                else
                    flattenTypes(input);
                var uniq: [flat_input.len]type = undefined;
                var total: usize = 0;
                for (flat_input) |candidate| {
                    var duplicate: bool = false;
                    for (uniq[0..total]) |existing| {
                        if (existing == candidate) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        uniq[total] = candidate;
                        total += 1;
                    }
                }
                var outer: usize = 0;
                while (outer < total) : (outer += 1) {
                    var inner_cursor: usize = outer + 1;
                    while (inner_cursor < total) : (inner_cursor += 1) {
                        const left: []const u8 = @typeName(uniq[outer]);
                        const right: []const u8 = @typeName(uniq[inner_cursor]);
                        if (std.mem.order(u8, right, left) == .lt) {
                            const swap: type = uniq[outer];
                            uniq[outer] = uniq[inner_cursor];
                            uniq[inner_cursor] = swap;
                        }
                    }
                }
                for (uniq[0..total]) |T| {
                    if (componentIndex(T) == null) {
                        @compileError("Component type was not declared in ECS(...).");
                    }
                }
                const Keep = struct {
                    const values: [flat_input.len]type = uniq;
                    const count: usize = total;
                };
                break :canon Keep.values[0..Keep.count];
            };
        }
        /// Checks whether one archetype stores a type, by archetype id.
        /// - `k` - archetype id. Must be comptime-known.
        /// - `Item` - component type to look up.
        ///
        /// Returns `bool` - true when the archetype stores the type.
        fn archHasType(comptime k: usize, comptime Item: type) bool {
            for (0..Tables.arch_lens[k]) |i| {
                if (Tables.arch_types[k][i] == Item) {
                    return true;
                }
            }
            return false;
        }
        /// Maps a type to its column index inside one archetype, by archetype id.
        /// - `k` - archetype id. Must be comptime-known.
        /// - `Item` - component type to locate. Must be stored in the archetype.
        ///
        /// Returns `usize` - column index of the type.
        fn archIndexOf(comptime k: usize, comptime Item: type) usize {
            for (0..Tables.arch_lens[k]) |i| {
                if (Tables.arch_types[k][i] == Item) {
                    return i;
                }
            }
            @compileError("Type is not part of this archetype.");
        }
        /// Compares one archetype against a canonical query for exact equality.
        /// - `k` - archetype id. Must be comptime-known.
        /// - `q` - canonical query types.
        ///
        /// Returns `bool` - true when the sets match exactly.
        fn archTypesEqual(comptime k: usize, comptime q: []const type) bool {
            if (Tables.arch_lens[k] != q.len) {
                return false;
            }
            for (0..Tables.arch_lens[k]) |i| {
                if (Tables.arch_types[k][i] != q[i]) {
                    return false;
                }
            }
            return true;
        }
        /// Component ids of one archetype, sorted ascending.
        /// - `k` - archetype id. Must be comptime-known.
        ///
        /// Returns `[]const u32` - component id list of the archetype.
        fn archetypeCompIds(comptime k: usize) []const u32 {
            return Tables.arch_comp[k][0..Tables.arch_lens[k]];
        }
        /// Checks whether a sorted id list contains a component id.
        /// - `ids` - sorted component ids.
        /// - `target` - component id to look up.
        ///
        /// Returns `bool` - true when the id is present.
        fn containsId(comptime ids: []const u32, comptime target: u32) bool {
            for (ids) |id| {
                if (id == target) {
                    return true;
                }
            }
            return false;
        }
        /// Resolves a component type to its dense id.
        /// - `T` - component type. Must be declared in `ECS(...)`.
        ///
        /// Returns `u32` - component id, an index into `components`.
        pub fn componentId(comptime T: type) u32 {
            const idx = comptime componentIndex(T) orelse
                @compileError("Unknown component: type was not declared in ECS(...).");
            return @intCast(idx);
        }
        /// Resolves a component type to its static descriptor.
        /// - `T` - component type. Must be declared in `ECS(...)`.
        ///
        /// Returns `*const ComponentInfo` - shared static descriptor.
        pub fn componentInfo(comptime T: type) *const ComponentInfo {
            return &Ecs.components[Ecs.componentId(T)];
        }
        /// Resolves a component bundle to its archetype id. Order does not matter,
        /// nested tuples are flattened.
        /// - `types` - component bundle. Must exactly match a declared archetype.
        ///
        /// Returns `u32` - archetype id, an index into `archetypes`.
        pub fn archetypeId(comptime types: anytype) u32 {
            const q = comptime canonicalQuery(types);
            inline for (0..ARCH_COUNT) |k| {
                if (comptime archTypesEqual(k, q)) {
                    return @intCast(k);
                }
            }
            @compileError("Unknown archetype: this combination was not declared in ECS(...).");
        }
        /// Returns the static descriptor of the archetype with the given id.
        /// - `id` - archetype id, an index into `archetypes`.
        ///
        /// Returns `*const ArchetypeInfo` - shared static descriptor.
        pub fn archetypeInfoById(id: u32) *const ArchetypeInfo {
            return &Ecs.archetypes[id];
        }
        /// Builds the SOA storage type for one archetype from its component types.
        /// - `arch_types_fixed` - canonical component types padded to `max_len`, defining the column order.
        /// - `arch_len` - number of valid entries in `arch_types_fixed`.
        ///
        /// Returns `type` - structure-of-arrays storage with component columns and entity refs.
        fn MakeData(comptime arch_types_fixed: [max_len]type, comptime arch_len: usize) type {
            const ArchTypes: []const type = arch_types_fixed[0..arch_len];
            const ListTypes: [ArchTypes.len]type = blk: {
                var tmp: [ArchTypes.len]type = undefined;
                for (ArchTypes, 0..) |T, i| {
                    tmp[i] = std.ArrayListUnmanaged(T);
                }
                break :blk tmp;
            };
            const Lists = std.meta.Tuple(&ListTypes);
            return struct {
                const Self = @This();
                /// One column per component type. Indexed by the canonical position.
                lists: Lists,
                /// One row per stored entity, parallel to the component columns.
                refs: std.ArrayListUnmanaged(EntityReference) = .empty,
                /// Builds empty storage. Usable in comptime initializers.
                ///
                /// Returns `Self` - storage with every list empty.
                pub fn empty() Self {
                    var lists: Lists = undefined;
                    inline for (0..ArchTypes.len) |i| {
                        lists[i] = .empty;
                    }
                    return Self{
                        .lists = lists,
                        .refs = .empty,
                    };
                }
                /// Locates the column index storing the given component type.
                /// - `Target` - component type to locate. Must be stored here.
                ///
                /// Returns `usize` - canonical column index.
                fn indexOf(comptime Target: type) usize {
                    return Ecs.indexOfType(ArchTypes, Target);
                }
                /// Counts stored rows.
                /// - `self` - storage to inspect.
                ///
                /// Returns `u32` - current row count.
                pub fn count(self: *const Self) u32 {
                    return @intCast(self.refs.items.len);
                }
                /// Checks whether a row exists at the given position.
                /// - `self` - storage to inspect.
                /// - `index` - row position.
                ///
                /// Returns `bool` - true when the position is in range.
                pub fn exists(self: *const Self, index: u32) bool {
                    return index < self.refs.items.len;
                }
                /// Fetches the entity reference stored at the given position.
                /// - `self` - storage to inspect.
                /// - `index` - row position.
                ///
                /// Returns `EntityReference` - reference stored in the row.
                pub fn entity(self: *const Self, index: u32) EcsError!EntityReference {
                    if (!self.exists(index)) {
                        return EcsError.IndexOutOfBounds;
                    }
                    return self.refs.items[index];
                }
                /// Returns a pointer to one component value. The pointer is mutable
                /// even though the receiver is const: columns live in global
                /// storage, the storage header itself is never modified.
                /// - `self` - storage to inspect.
                /// - `Target` - component type to fetch. Must be stored here.
                /// - `index` - row position.
                ///
                /// Returns `*Target` - pointer into the component column.
                pub fn get(
                    self: *const Self,
                    comptime Target: type,
                    index: u32,
                ) EcsError!*Target {
                    const column: *const std.ArrayListUnmanaged(Target) =
                        &self.lists[comptime Self.indexOf(Target)];
                    if (index >= column.items.len) {
                        return EcsError.IndexOutOfBounds;
                    }
                    // Safe: every Data instance lives in the mutable global
                    // `storages` tuple, so the column is never truly immutable.
                    return @constCast(&column.items[index]);
                }
                /// Exposes a whole component column as a read-only list.
                /// - `self` - storage to inspect.
                /// - `Target` - component type to expose. Must be stored here.
                ///
                /// Returns `ReadOnlyList` - live view of the component column.
                pub fn list(
                    self: *const Self,
                    comptime Target: type,
                ) ReadOnlyList(Target) {
                    const column: *const std.ArrayListUnmanaged(Target) =
                        &self.lists[comptime Self.indexOf(Target)];
                    return ReadOnlyList(Target).init(column);
                }
                /// Exposes the entity reference column as a read-only list.
                /// - `self` - storage to inspect.
                ///
                /// Returns `ReadOnlyList` - live view of the reference column.
                pub fn entities(self: *const Self) ReadOnlyList(EntityReference) {
                    return ReadOnlyList(EntityReference).init(&self.refs);
                }
                /// Exposes the entity reference column.
                /// - `self` - storage to inspect.
                ///
                /// Returns `[]const EntityReference` - read-only reference list.
                pub fn entityList(self: *const Self) []const EntityReference {
                    return self.refs.items;
                }
                /// Appends an empty row across all columns plus the reference.
                /// - `self` - storage to mutate.
                /// - `allocator` - funds row allocation.
                /// - `reference` - handle stored alongside the components.
                ///
                /// Returns `u32` - position of the new row.
                fn add(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    reference: *const EntityReference,
                ) EcsError!u32 {
                    inline for (0..ArchTypes.len) |i| {
                        try self.lists[i].append(allocator, undefined);
                    }
                    try self.refs.append(allocator, reference.*);
                    return @intCast(self.refs.items.len - 1);
                }
                /// Removes a row across all columns via swap with the last row.
                /// - `self` - storage to mutate.
                /// - `index` - row position to remove.
                ///
                /// Returns `?EntityReference` - relocated reference, or null when the last row was removed.
                fn remove(self: *Self, index: u32) ?EntityReference {
                    const previous_count: usize = self.refs.items.len;
                    if (index >= previous_count) {
                        return null;
                    }
                    inline for (0..ArchTypes.len) |i| {
                        _ = self.lists[i].swapRemove(index);
                    }
                    _ = self.refs.swapRemove(index);
                    const last: usize = previous_count - 1;
                    if (index == last) {
                        return null;
                    }
                    return self.refs.items[index];
                }
                /// Releases every column list and the reference list.
                /// - `self` - storage to release.
                /// - `allocator` - allocator that funded the lists.
                fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                    inline for (0..ArchTypes.len) |i| {
                        self.lists[i].deinit(allocator);
                    }
                    self.refs.deinit(allocator);
                }
            };
        }
        /// Concrete storage types, one per archetype, in archetype id order.
        const DataTypes: [ARCH_COUNT]type = blk: {
            var tmp: [ARCH_COUNT]type = undefined;
            for (0..ARCH_COUNT) |j| {
                tmp[j] = MakeData(Tables.arch_types[j], Tables.arch_lens[j]);
            }
            break :blk tmp;
        };
        /// Heterogeneous tuple holding every archetype storage.
        const Storages = std.meta.Tuple(&DataTypes);
        /// Every archetype storage. Starts empty; rows are added at runtime.
        var storages: Storages = blk: {
            var tmp: Storages = undefined;
            for (0..ARCH_COUNT) |j| {
                tmp[j] = DataTypes[j].empty();
            }
            break :blk tmp;
        };
        /// Entity slots in SoA form. Position `id` in every column describes
        /// one slot: `entity_generation[id]` is the live generation,
        /// `entity_archetype[id]` owns the row, `entity_row[id]` is the row.
        /// Pending lifecycle states live densely packed in
        /// `entity_state_words`, 2 bits per slot, 4 slots per byte.
        /// A slot id always equals its position; ids are never stored.
        var entity_generation: std.ArrayListUnmanaged(u8) = .empty;
        /// Owning archetype per slot, parallel to `entity_generation`.
        var entity_archetype: std.ArrayListUnmanaged(u32) = .empty;
        /// Row inside the owning archetype storage, parallel to `entity_generation`.
        var entity_row: std.ArrayListUnmanaged(u32) = .empty;
        /// Packed pending states, 4 slots per byte, 2 bits per slot.
        /// Length is `ceil(entityStateLen() / 4)`; slot `id` uses bits
        /// `2 * (id % 4)` of `words[id / 4]`.
        var entity_state_words: std.ArrayListUnmanaged(u8) = .empty;
        /// Stack of freed entity ids ready for reuse.
        var free_ids: std.ArrayListUnmanaged(u32) = .empty;
        /// Counts entity slots. Backs the packed state store length.
        /// - Returns `usize` - number of slots ever assigned.
        fn entityStateLen() usize {
            return Ecs.entity_generation.items.len;
        }
        /// Reads one packed 2-bit state. Caller must ensure `id` is in range.
        /// - `entity_index` - slot id to read.
        ///
        /// Returns `EntityState` - stored state of the slot.
        fn getEntityState(entity_index: u32) EntityState {
            const word: u8 = Ecs.entity_state_words.items[entity_index >> 2];
            const shift: u3 = @intCast((entity_index & 3) * 2);
            const bits: u2 = @intCast((word >> shift) & 0b11);
            return @enumFromInt(bits);
        }
        /// Writes one packed 2-bit state. Caller must ensure `id` is in range
        /// and words already cover it (see `ensureStateWords`).
        /// - `entity_index` - slot id to write.
        /// - `next` - pending state to store.
        fn setEntityState(entity_index: u32, next: EntityState) void {
            const slot: *u8 = &Ecs.entity_state_words.items[entity_index >> 2];
            const shift: u3 = @intCast((entity_index & 3) * 2);
            const mask: u8 = @as(u8, 0b11) << shift;
            slot.* = (slot.* & ~mask) | (@as(u8, @intFromEnum(next)) << shift);
        }
        /// Grows the packed words with zero (`none`) bytes to cover `slot_count` slots.
        /// - `allocator` - funds the growth.
        /// - `slot_count` - number of slots that must be addressable afterwards.
        fn ensureStateWords(allocator: std.mem.Allocator, slot_count: usize) EcsError!void {
            const need: usize = (slot_count + 3) >> 2;
            const have: usize = Ecs.entity_state_words.items.len;
            if (need > have) {
                try Ecs.entity_state_words.appendNTimes(allocator, 0, need - have);
            }
        }
        /// Requires the referenced slot to be alive and idle (no queued command).
        /// - `ref` - entity reference to validate.
        fn requireIdle(ref: EntityReference) EcsError!u32 {
            if (!ref.isAlive()) {
                return EcsError.EntityIsNotAlive;
            }
            const entity_index: u32 = ref.id;
            if (Ecs.getEntityState(entity_index) != .none) {
                return EcsError.EntityHasPendingCommand;
            }
            return entity_index;
        }
        /// Marks a slot as pending. Caller must have validated via `requireIdle`.
        /// - `entity_index` - slot id to mark.
        /// - `next` - pending state to store.
        fn markPending(entity_index: u32, next: EntityState) void {
            Ecs.setEntityState(entity_index, next);
        }
        /// Clears the pending flag of a slot, ignoring never-assigned ids.
        /// Used when discarding queued commands after a failing system.
        /// - `entity_index` - slot id to release.
        fn clearPending(entity_index: u32) void {
            if (entity_index < Ecs.entityStateLen()) {
                Ecs.setEntityState(entity_index, .none);
            }
        }
        /// Names the storage type of one archetype id. Useful to name the
        /// pointer returned by `storage` without repeating the lookup.
        /// - `id` - archetype id. Must be comptime-known.
        ///
        /// Returns `type` - concrete SOA storage type of the archetype.
        /// Private: direct storage access can reallocate; use `SystemHandler`.
        fn Storage(comptime id: usize) type {
            return DataTypes[id];
        }
        /// Returns a direct pointer to the storage of the given component bundle.
        /// Zero-cost typed access with no dispatch.
        /// Private: direct storage access can reallocate; use `SystemHandler`.
        /// - `types` - component bundle. Must exactly match a declared archetype.
        ///
        /// Returns `*Storage` - live SOA storage of the archetype.
        fn storage(comptime types: anytype) *Storage(archetypeId(types)) {
            const id = comptime archetypeId(types);
            return &Ecs.storages[id];
        }
        /// Creates an entity inside the given archetype, reusing a free slot when possible.
        /// Private: immediate creation can reallocate; systems use `cmdCreate`.
        /// - `allocator` - funds record and archetype row allocation.
        /// - `types` - component bundle of the destination archetype. Must be declared in `ECS(...)`.
        ///
        /// Returns `EntityReference` - handle of the new entity.
        fn create(
            allocator: std.mem.Allocator,
            comptime types: anytype,
        ) EcsError!EntityReference {
            const id = comptime archetypeId(types);
            return Ecs.createById(allocator, id);
        }
        /// Creates an entity inside the archetype with the given id.
        /// Private: used by command flushing.
        /// - `allocator` - funds record and archetype row allocation.
        /// - `id` - destination archetype id, an index into `archetypes`.
        ///
        /// Returns `EntityReference` - handle of the new entity.
        fn createById(allocator: std.mem.Allocator, id: u32) EcsError!EntityReference {
            var new_id: u32 = 0;
            var new_gen: u8 = 0;
            if (Ecs.free_ids.pop()) |recycled| {
                new_id = recycled;
                new_gen = Ecs.entity_generation.items[new_id];
            } else {
                new_id = @intCast(Ecs.entity_generation.items.len);
                try Ecs.entity_generation.append(allocator, 0);
                try Ecs.entity_archetype.append(allocator, id);
                try Ecs.entity_row.append(allocator, 0);
                try Ecs.ensureStateWords(allocator, Ecs.entity_generation.items.len);
                new_gen = 0;
            }
            const reference = EntityReference{
                .id = @intCast(new_id),
                .gen = new_gen,
            };
            const index: u32 = blk: {
                inline for (0..ARCH_COUNT) |k| {
                    if (id == k) {
                        break :blk try Ecs.storages[k].add(allocator, &reference);
                    }
                }
                unreachable;
            };
            Ecs.entity_generation.items[new_id] = new_gen;
            Ecs.entity_archetype.items[new_id] = id;
            Ecs.entity_row.items[new_id] = index;
            Ecs.setEntityState(new_id, .none);
            return reference;
        }
        /// Counts entities stored in the given archetype.
        /// - `types` - component bundle. Must exactly match a declared archetype.
        ///
        /// Returns `u32` - current row count.
        pub fn count(comptime types: anytype) u32 {
            const id = comptime archetypeId(types);
            return Ecs.storages[id].count();
        }
        /// Counts entities stored in the archetype with the given id.
        /// - `id` - archetype id, an index into `archetypes`.
        ///
        /// Returns `u32` - current row count.
        pub fn countById(id: u32) u32 {
            inline for (0..ARCH_COUNT) |k| {
                if (id == k) {
                    return Ecs.storages[k].count();
                }
            }
            unreachable;
        }
        /// Returns a pointer to one component value at a row. The pointer is
        /// mutable: component data lives in global storage, no handle state
        /// is modified by the lookup.
        /// - `arch_id` - archetype id owning the row.
        /// - `T` - component type, must be stored in the archetype.
        /// - `index` - row position.
        ///
        /// Returns `*T` - pointer into the component column.
        /// Private: use `SystemHandler.getComponent`.
        fn getComponent(
            arch_id: u32,
            comptime T: type,
            index: u32,
        ) EcsError!*T {
            inline for (0..ARCH_COUNT) |k| {
                if (arch_id == k) {
                    if (comptime !archHasType(k, T)) {
                        return EcsError.ComponentNotFoundInArchetype;
                    }
                    const col = comptime archIndexOf(k, T);
                    const column = &Ecs.storages[k].lists[col];
                    if (index >= column.items.len) {
                        return EcsError.IndexOutOfBounds;
                    }
                    return &column.items[index];
                }
            }
            unreachable;
        }
        /// Copies values of components shared by two archetype rows.
        /// Every shared component is copied with a typed struct assignment.
        /// - `src_id` - archetype to read from.
        /// - `src_index` - row position in the source storage.
        /// - `dst_id` - archetype to write to.
        /// - `dst_index` - row position in the destination storage.
        fn copyShared(
            src_id: u32,
            src_index: u32,
            dst_id: u32,
            dst_index: u32,
        ) void {
            inline for (0..ARCH_COUNT) |s| {
                inline for (0..ARCH_COUNT) |d| {
                    if (src_id == s and dst_id == d) {
                        Ecs.copyBetween(s, d, src_index, dst_index);
                        return;
                    }
                }
            }
            unreachable;
        }
        /// Copies shared components between two comptime-known archetypes.
        /// - `s` - source archetype id. Must be comptime-known.
        /// - `d` - destination archetype id. Must be comptime-known.
        /// - `src_index` - row position in the source storage.
        /// - `dst_index` - row position in the destination storage.
        fn copyBetween(
            comptime s: usize,
            comptime d: usize,
            src_index: u32,
            dst_index: u32,
        ) void {
            inline for (0..Tables.arch_lens[d]) |ti| {
                const T: type = Tables.arch_types[d][ti];
                if (comptime archHasType(s, T)) {
                    const sc = comptime archIndexOf(s, T);
                    Ecs.storages[d].lists[ti].items[dst_index] =
                        Ecs.storages[s].lists[sc].items[src_index];
                }
            }
        }
        /// Binary-searches a sorted component id list.
        /// - `ids` - sorted component ids.
        /// - `target` - component id to look up.
        ///
        /// Returns `?usize` - position inside the list, or null when absent.
        fn binarySearchIds(ids: []const u32, target: u32) ?usize {
            var low: usize = 0;
            var high: usize = ids.len;
            while (low < high) {
                const mid: usize = low + (high - low) / 2;
                if (ids[mid] < target) {
                    low = mid + 1;
                } else if (ids[mid] > target) {
                    high = mid;
                } else {
                    return mid;
                }
            }
            return null;
        }
        /// Maps a component id to its column index inside an archetype.
        /// - `arch_id` - archetype id, an index into `archetypes`.
        /// - `comp_id` - component id to look up.
        ///
        /// Returns `?usize` - column index, or null when the component is absent.
        pub fn columnOf(arch_id: u32, comp_id: u32) ?usize {
            return binarySearchIds(Ecs.archetypes[arch_id].component_ids, comp_id);
        }
        /// Checks whether the archetype stores the given component.
        /// - `arch_id` - archetype id, an index into `archetypes`.
        /// - `comp_id` - component id to look up.
        ///
        /// Returns `bool` - true when the component is stored.
        pub fn hasComponent(arch_id: u32, comp_id: u32) bool {
            return Ecs.columnOf(arch_id, comp_id) != null;
        }
        /// Typed view over one archetype, exposing mutable component columns.
        /// - `include` - component bundle; the matched archetype is found via
        ///   `getPages` or `getArchetypePage`.
        ///
        /// Returns `type` - page type holding a single archetype id.
        /// Private: pages are only issued by `SystemHandler`.
        fn Page(comptime include: anytype) type {
            const query = comptime canonicalQuery(include);
            return struct {
                const PageNamespace = @This();
                /// Archetype this page reads and writes.
                arch_id: u32,
                /// Returns the whole mutable column of one component.
                /// - `self` - page to inspect.
                /// - `T` - component type, must be part of the query.
                ///
                /// Returns `[]T` - mutable slice over the component column.
                pub fn get(self: *const PageNamespace, comptime T: type) []T {
                    comptime {
                        if (!hasType(query, T)) {
                            @compileError("Requested component type is not part of this page.");
                        }
                    }
                    inline for (0..ARCH_COUNT) |k| {
                        if (self.arch_id == k) {
                            if (comptime !archHasType(k, T)) {
                                return &[0]T{};
                            }
                            const col = comptime archIndexOf(k, T);
                            return Ecs.storages[k].lists[col].items;
                        }
                    }
                    unreachable;
                }
                /// Returns the entity reference column, read-only.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const EntityReference` - read-only reference list.
                pub fn entities(self: *const PageNamespace) []const EntityReference {
                    inline for (0..ARCH_COUNT) |k| {
                        if (self.arch_id == k) {
                            return Ecs.storages[k].refs.items;
                        }
                    }
                    unreachable;
                }
                /// Returns an immutable reference to the source archetype info.
                /// - `self` - page to inspect.
                ///
                /// Returns `*const ArchetypeInfo` - source archetype descriptor.
                pub fn archetypeInfo(self: *const PageNamespace) *const ArchetypeInfo {
                    return &Ecs.archetypes[self.arch_id];
                }
            };
        }
        /// Iterator over pages of archetypes containing all `include` components
        /// and none of the `exclude` components.
        /// The match list is precomputed in comptime; iteration needs no allocator.
        /// - `include` - component bundle that must be present.
        /// - `exclude` - component bundle that must be absent. `null` and empty
        ///   bundles are equivalent to no exclusion.
        ///
        /// Returns `type` - iterator over the matched archetype ids.
        /// Private: iterators are only issued by `SystemHandler`.
        fn PageIterator(comptime include: anytype, comptime exclude: anytype) type {
            const query = comptime canonicalQuery(include);
            const qids: [query.len]u32 = blk: {
                var tmp: [query.len]u32 = undefined;
                for (query, 0..) |T, i| {
                    tmp[i] = @intCast(componentIndex(T).?);
                }
                break :blk tmp;
            };
            // Exclusion is checked for emptiness up front: `null` or an empty
            // bundle means no exclusion at all.
            const deny = comptime blk: {
                if (@TypeOf(exclude) == @TypeOf(null)) {
                    break :blk &[_]type{};
                }
                const flat = canonicalQueryAllowEmpty(exclude);
                if (flat.len == 0) {
                    break :blk &[_]type{};
                }
                break :blk flat;
            };
            comptime {
                for (query) |T| {
                    for (deny) |D| {
                        if (T == D) {
                            @compileError("A component cannot be both included and excluded.");
                        }
                    }
                }
            }
            const deny_ids: [deny.len]u32 = blk: {
                var tmp: [deny.len]u32 = undefined;
                for (deny, 0..) |T, i| {
                    tmp[i] = @intCast(componentIndex(T).?);
                }
                break :blk tmp;
            };
            const matched = blk: {
                var list: [ARCH_COUNT]u32 = undefined;
                var total: usize = 0;
                for (0..ARCH_COUNT) |k| {
                    const ids = Tables.arch_comp[k][0..Tables.arch_lens[k]];
                    var ok: bool = true;
                    for (qids) |qid| {
                        var has: bool = false;
                        for (ids) |id| {
                            if (id == qid) {
                                has = true;
                                break;
                            }
                        }
                        if (!has) {
                            ok = false;
                            break;
                        }
                    }
                    for (deny_ids) |did| {
                        for (ids) |id| {
                            if (id == did) {
                                ok = false;
                                break;
                            }
                        }
                        if (!ok) {
                            break;
                        }
                    }
                    if (ok) {
                        list[total] = @intCast(k);
                        total += 1;
                    }
                }
                break :blk .{ .list = list, .len = total };
            };
            return struct {
                /// Current match position.
                index: usize = 0,
                /// Returns the next matching page, or null when exhausted.
                /// - `self` - iterator to advance.
                ///
                /// Returns `?Page(include)` - next page, or null at the end.
                pub fn next(self: *@This()) ?Page(include) {
                    if (self.index >= matched.len) {
                        return null;
                    }
                    const id: u32 = matched.list[self.index];
                    self.index += 1;
                    return Page(include){
                        .arch_id = id,
                    };
                }
            };
        }
        /// Handle passed to every system function. It is the only way to read
        /// page data and the only way to schedule structural changes.
        /// Data obtained through the handler (pointers, slices, pages) is valid
        /// only until the current system returns: queued commands are applied
        /// between systems and may reallocate storages.
        pub const SystemHandler = struct {
            /// Allocator funding the command queue and flushed changes.
            allocator: std.mem.Allocator,
            /// Builds an iterator over pages of archetypes containing all `include`
            /// components and none of the `exclude` components.
            /// - `self` - handler of the running system.
            /// - `include` - component bundle that must be present.
            /// - `exclude` - component bundle that must be absent. `null` and empty
            ///   bundles are equivalent to no exclusion.
            ///
            /// Returns `PageIterator` - stack-owned iterator, no allocator needed.
            pub fn pages(
                self: *const SystemHandler,
                comptime include: anytype,
                comptime exclude: anytype,
            ) PageIterator(include, exclude) {
                _ = self;
                return .{};
            }
            /// Returns the page of one exact archetype.
            /// - `self` - handler of the running system.
            /// - `bundle` - component bundle. Must exactly match a declared archetype.
            ///
            /// Returns `Page(bundle)` - page of the matched archetype.
            pub fn page(
                self: *const SystemHandler,
                comptime bundle: anytype,
            ) Page(bundle) {
                _ = self;
                return Page(bundle){
                    .arch_id = comptime archetypeId(bundle),
                };
            }
            /// Counts entities in archetypes containing all `include` components
            /// and none of the `exclude` components.
            /// - `self` - handler of the running system.
            /// - `include` - component bundle that must be present.
            /// - `exclude` - component bundle that must be absent.
            ///
            /// Returns `u32` - total row count over the matched archetypes.
            pub fn count(
                self: *const SystemHandler,
                comptime include: anytype,
                comptime exclude: anytype,
            ) u32 {
                var total: u32 = 0;
                var it = self.pages(include, exclude);
                while (it.next()) |p| {
                    total += Ecs.countById(p.arch_id);
                }
                return total;
            }
            /// Returns a pointer to one component of the referenced entity.
            /// - `self` - handler of the running system.
            /// - `ref` - entity reference to resolve. Must be alive.
            /// - `T` - component type, must be stored in the entity archetype.
            ///
            /// Returns `*T` - pointer into the owning component column.
            pub fn getComponent(
                self: *const SystemHandler,
                ref: EntityReference,
                comptime T: type,
            ) EcsError!*T {
                _ = self;
                if (!ref.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = ref.id;
                return Ecs.getComponent(
                    Ecs.entity_archetype.items[entity_index],
                    T,
                    Ecs.entity_row.items[entity_index],
                );
            }
            /// Queues entity creation. Applied after the current system finishes.
            /// - `self` - handler of the running system.
            /// - `bundle` - component bundle of the new entity. Must be declared in `ECS(...)`.
            /// - `values` - tuple of component values, one per bundle component,
            ///   in any order. Types must match the bundle exactly.
            pub fn cmdCreate(
                self: *const SystemHandler,
                comptime bundle: anytype,
                values: anytype,
            ) EcsError!void {
                const arch = comptime archetypeId(bundle);
                const blob = try Ecs.packValues(arch, values, self.allocator);
                errdefer self.allocator.free(blob);
                try Ecs.commands.append(self.allocator, .{ .create = .{
                    .arch = @intCast(arch),
                    .bytes = blob,
                } });
            }
            /// Queues creation of `n` entities with identical component values.
            /// - `self` - handler of the running system.
            /// - `bundle` - component bundle of the new entities.
            /// - `values` - tuple of component values shared by all `n` entities.
            /// - `n` - number of entities to create.
            pub fn cmdCreateN(
                self: *const SystemHandler,
                comptime bundle: anytype,
                values: anytype,
                n: u32,
            ) EcsError!void {
                const arch: u32 = @intCast(comptime archetypeId(bundle));
                const blob = try Ecs.packValues(arch, values, self.allocator);
                defer self.allocator.free(blob);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const dup = try self.allocator.dupe(u8, blob);
                    errdefer self.allocator.free(dup);
                    try Ecs.commands.append(self.allocator, .{ .create = .{
                        .arch = arch,
                        .bytes = dup,
                    } });
                }
            }
            /// Queues entity destruction. Applied after the current system finishes.
            /// Fails with `EntityIsNotAlive` when the reference is stale and
            /// with `EntityHasPendingCommand` when the slot already has a
            /// queued destroy or migrate: one load of `entity_state`.
            /// - `self` - handler of the running system.
            /// - `ref` - entity reference to destroy.
            pub fn cmdDestroy(self: *const SystemHandler, ref: EntityReference) EcsError!void {
                const entity_index = try Ecs.requireIdle(ref);
                try Ecs.commands.append(self.allocator, .{ .destroy = ref });
                Ecs.markPending(entity_index, .pending_destroy);
            }
            /// Queues entity migration into another archetype.
            /// Same strictness as `cmdDestroy`: stale or already-pending
            /// slots are rejected at queue time, so a migrate of a
            /// destroy-pending entity can never be queued.
            /// - `self` - handler of the running system.
            /// - `ref` - entity reference to move.
            /// - `dest` - component bundle of the destination archetype.
            /// - `copy` - when true, shared component values are carried over.
            pub fn cmdMigrate(
                self: *const SystemHandler,
                ref: EntityReference,
                comptime dest: anytype,
                copy: bool,
            ) EcsError!void {
                const entity_index = try Ecs.requireIdle(ref);
                const dest_id: u32 = @intCast(comptime archetypeId(dest));
                try Ecs.commands.append(self.allocator, .{ .migrate = .{
                    .ref = ref,
                    .dest = dest_id,
                    .copy = copy,
                } });
                Ecs.markPending(entity_index, .pending_migrate);
            }
            /// Queues destruction of every entity on pages matching `include`
            /// and `exclude`. Applied after the current system finishes.
            /// Each row is validated like `cmdDestroy`, so an already-pending
            /// row aborts the whole batch with `EntityHasPendingCommand`.
            /// - `self` - handler of the running system.
            /// - `include` - component bundle that must be present.
            /// - `exclude` - component bundle that must be absent.
            pub fn cmdDestroyPages(
                self: *const SystemHandler,
                comptime include: anytype,
                comptime exclude: anytype,
            ) EcsError!void {
                var it = self.pages(include, exclude);
                while (it.next()) |p| {
                    for (p.entities()) |ref| {
                        const entity_index = try Ecs.requireIdle(ref);
                        try Ecs.commands.append(self.allocator, .{ .destroy = ref });
                        Ecs.markPending(entity_index, .pending_destroy);
                    }
                }
            }
            /// Queues destruction of every entity in one exact archetype.
            /// Applied after the current system finishes. Marks every row
            /// pending up front, so a later `cmdDestroy`/`cmdMigrate` of the
            /// same slot fails instead of duplicating the command.
            /// - `self` - handler of the running system.
            /// - `bundle` - component bundle. Must exactly match a declared archetype.
            pub fn cmdDestroyPage(
                self: *const SystemHandler,
                comptime bundle: anytype,
            ) EcsError!void {
                const id: u32 = @intCast(comptime archetypeId(bundle));
                inline for (0..ARCH_COUNT) |k| {
                    if (id == k) {
                        for (Ecs.storages[k].refs.items) |ref| {
                            const entity_index = try Ecs.requireIdle(ref);
                            Ecs.markPending(entity_index, .pending_destroy);
                        }
                        break;
                    }
                }
                try Ecs.commands.append(self.allocator, .{ .destroy_page = id });
            }
        };
        /// Deferred structural change, applied between systems in FIFO order.
        const Command = union(enum) {
            /// Create an entity; `bytes` holds packed component values in column order.
            create: struct {
                arch: u32,
                bytes: []u8,
            },
            /// Destroy an entity; skipped when the reference is stale.
            destroy: EntityReference,
            /// Migrate an entity; skipped when the reference is stale.
            migrate: struct {
                ref: EntityReference,
                dest: u32,
                copy: bool,
            },
            /// Destroy every entity in one exact archetype.
            destroy_page: u32,
        };
        /// Queued structural changes of the running system.
        var commands: std.ArrayListUnmanaged(Command) = .empty;
        /// Finds the values-tuple field holding the given component type.
        /// - `V` - values tuple type.
        /// - `T` - component type to locate. Must be present exactly once.
        ///
        /// Returns `usize` - field index inside the values tuple.
        fn valuesFieldIndex(comptime V: type, comptime T: type) usize {
            const fields = @typeInfo(V).@"struct".fields;
            inline for (0..fields.len) |j| {
                if (fields[j].type == T) {
                    return j;
                }
            }
            unreachable;
        }
        /// Packs component values into a byte blob in canonical column order.
        /// - `arch` - destination archetype id. Must be comptime-known.
        /// - `values` - tuple of component values matching the archetype exactly.
        /// - `allocator` - funds the blob.
        ///
        /// Returns `[]u8` - owned blob, freed by the caller.
        fn packValues(
            comptime arch: usize,
            values: anytype,
            allocator: std.mem.Allocator,
        ) EcsError![]u8 {
            const Ar = Tables.arch_lens[arch];
            const VType = @TypeOf(values);
            const VInfo = @typeInfo(VType);
            comptime {
                if (VInfo != .@"struct" or !VInfo.@"struct".is_tuple) {
                    @compileError("values must be a tuple of component values matching the bundle.");
                }
                if (VInfo.@"struct".fields.len != Ar) {
                    @compileError("values count must match the bundle component count.");
                }
                for (0..Ar) |i| {
                    const T = Tables.arch_types[arch][i];
                    var found: usize = 0;
                    for (0..VInfo.@"struct".fields.len) |j| {
                        const FT = VInfo.@"struct".fields[j].type;
                        if (FT == type) {
                            @compileError("values must hold component values, not types.");
                        }
                        if (@typeInfo(FT) != .@"struct") {
                            @compileError("Every value must be a struct value.");
                        }
                        if (FT == EntityReference) {
                            @compileError("EntityReference cannot be a component.");
                        }
                        if (FT == T) {
                            found += 1;
                        }
                    }
                    if (found != 1) {
                        @compileError("values must contain each bundle component exactly once.");
                    }
                }
            }
            const total_size = comptime blk: {
                var s: usize = 0;
                for (0..Ar) |i| {
                    s += @sizeOf(Tables.arch_types[arch][i]);
                }
                break :blk s;
            };
            const blob = try allocator.alloc(u8, total_size);
            errdefer allocator.free(blob);
            // NOTE: `values` is a comptime-known generic parameter, so field
            // addresses are unusable at runtime. `toBytes` copies by value.
            var cursor: usize = 0;
            inline for (0..Ar) |i| {
                const T = Tables.arch_types[arch][i];
                const j = comptime valuesFieldIndex(VType, T);
                const bytes = std.mem.toBytes(values[j]);
                @memcpy(blob[cursor..][0..bytes.len], &bytes);
                cursor += bytes.len;
            }
            return blob;
        }
        /// Applies every queued command in FIFO order, then clears the queue.
        /// Queue-time validation (`requireIdle`) already rejected duplicates,
        /// so flush only keeps a defensive `isAlive` guard. Immediate
        /// `destroy`/`migrateById` clear the pending flag they resolve.
        /// Private: runs automatically between systems; never call it directly,
        /// or pages held by user code may dangle after reallocation.
        /// - `allocator` - allocator that funded the queue and the changes.
        fn flushCommands(allocator: std.mem.Allocator) EcsError!void {
            defer Ecs.commands.clearRetainingCapacity();
            for (Ecs.commands.items) |cmd| {
                switch (cmd) {
                    .create => |c| {
                        errdefer allocator.free(c.bytes);
                        const created = try Ecs.createById(allocator, c.arch);
                        const created_row: u32 = Ecs.entity_row.items[created.id];
                        inline for (0..ARCH_COUNT) |k| {
                            if (c.arch == k) {
                                var off: usize = 0;
                                inline for (0..Tables.arch_lens[k]) |col| {
                                    const dst = std.mem.asBytes(&Ecs.storages[k].lists[col].items[created_row]);
                                    @memcpy(dst, c.bytes[off..][0..dst.len]);
                                    off += dst.len;
                                }
                            }
                        }
                        allocator.free(c.bytes);
                    },
                    .destroy => |ref| {
                        if (ref.isAlive()) {
                            try ref.destroy(allocator);
                        } else {
                            Ecs.clearPending(ref.id);
                        }
                    },
                    .migrate => |m| {
                        if (m.ref.isAlive()) {
                            _ = try m.ref.migrateById(allocator, m.dest, m.copy);
                        } else {
                            Ecs.clearPending(m.ref.id);
                        }
                    },
                    .destroy_page => |arch| {
                        inline for (0..ARCH_COUNT) |k| {
                            if (arch == k) {
                                for (Ecs.storages[k].refs.items) |ref| {
                                    const entity_index: u32 = ref.id;
                                    Ecs.entity_generation.items[entity_index] +%= 1;
                                    Ecs.setEntityState(entity_index, .none);
                                    try Ecs.free_ids.append(allocator, entity_index);
                                }
                                inline for (0..Tables.arch_lens[k]) |col| {
                                    Ecs.storages[k].lists[col].items.len = 0;
                                }
                                Ecs.storages[k].refs.items.len = 0;
                            }
                        }
                    },
                }
            }
        }
        /// Drops every queued command without applying it, freeing create blobs
        /// and releasing the pending flags set at queue time. Used when a
        /// system fails and on teardown.
        /// - `allocator` - allocator that funded the queue.
        fn discardCommands(allocator: std.mem.Allocator) void {
            for (Ecs.commands.items) |cmd| {
                switch (cmd) {
                    .create => allocator.free(cmd.create.bytes),
                    .destroy => |ref| Ecs.clearPending(ref.id),
                    .migrate => |m| Ecs.clearPending(m.ref.id),
                    .destroy_page => |arch| {
                        inline for (0..ARCH_COUNT) |k| {
                            if (arch == k) {
                                for (Ecs.storages[k].refs.items) |ref| {
                                    Ecs.clearPending(ref.id);
                                }
                            }
                        }
                    },
                }
            }
            Ecs.commands.clearRetainingCapacity();
        }
        /// Builds a schedule: a fixed, explicit order of system functions.
        /// Every system takes exactly one `*SystemHandler` parameter and returns
        /// `anyerror!void`. Queued commands are applied automatically after each
        /// system and before the next one.
        /// - `systems` - tuple of system functions, executed in tuple order.
        ///
        /// Returns `type` - runner namespace with a single `run` function.
        pub fn Schedule(comptime systems: anytype) type {
            const info = @typeInfo(@TypeOf(systems));
            if (info != .@"struct" or !info.@"struct".is_tuple) {
                @compileError("Schedule expects a tuple of system functions.");
            }
            for (0..info.@"struct".fields.len) |i| {
                const S = @TypeOf(systems[i]);
                const finfo = @typeInfo(S);
                if (finfo != .@"fn") {
                    @compileError("Every schedule entry must be a system function.");
                }
                const Fn = finfo.@"fn";
                if (Fn.params.len != 1) {
                    @compileError("Every system must take exactly one *SystemHandler parameter.");
                }
                const P = Fn.params[0].type orelse
                    @compileError("System parameter type must be known.");
                if (P != *SystemHandler) {
                    @compileError("Every system must take exactly one *SystemHandler parameter.");
                }
                const RT = Fn.return_type orelse
                    @compileError("System return type must be known.");
                const rinfo = @typeInfo(RT);
                if (rinfo != .error_union or rinfo.error_union.payload != void) {
                    @compileError("Every system must return an error union with void payload, e.g. anyerror!void.");
                }
            }
            return struct {
                const order = systems;
                /// Runs every system in schedule order, applying queued commands
                /// automatically after each system and before the next one.
                /// If a system fails, its unapplied commands are discarded and
                /// the error propagates; already applied changes stay applied.
                /// - `allocator` - funds the command queue and flushed changes.
                pub fn run(allocator: std.mem.Allocator) anyerror!void {
                    var handler = Ecs.SystemHandler{ .allocator = allocator };
                    errdefer Ecs.discardCommands(allocator);
                    inline for (order) |sys| {
                        try sys(&handler);
                        try Ecs.flushCommands(allocator);
                    }
                }
            };
        }
        /// Releases every storage and entity list owned by the namespace,
        /// then resets all runtime state so the ECS can be reused or safely
        /// deinitialized again.
        /// - `allocator` - allocator that funded all storage.
        pub fn deinit(allocator: std.mem.Allocator) void {
            inline for (0..ARCH_COUNT) |k| {
                Ecs.storages[k].deinit(allocator);
                Ecs.storages[k] = DataTypes[k].empty();
            }
            Ecs.discardCommands(allocator);
            Ecs.commands.deinit(allocator);
            Ecs.commands = .empty;
            Ecs.entity_generation.deinit(allocator);
            Ecs.entity_generation = .empty;
            Ecs.entity_archetype.deinit(allocator);
            Ecs.entity_archetype = .empty;
            Ecs.entity_row.deinit(allocator);
            Ecs.entity_row = .empty;
            Ecs.entity_state_words.deinit(allocator);
            Ecs.entity_state_words = .empty;
            Ecs.free_ids.deinit(allocator);
            Ecs.free_ids = .empty;
        }
    };
}
/// Horizontal and vertical coordinate component used by tests.
const Pos = struct { horizontal_coordinate: i32, vertical_coordinate: i32 };
/// Horizontal and vertical speed component used by tests.
const Vel = struct { horizontal_speed: f32, vertical_speed: f32 };
/// Current health amount component used by tests.
const Health = struct { current_value: u32 };
test "component identifiers are stable and dense" {
    const Ecs = ECS(.{ .{Pos}, .{Vel} });
    try std.testing.expect(Ecs.componentId(Pos) == Ecs.componentId(Pos));
    try std.testing.expect(Ecs.componentId(Pos) != Ecs.componentId(Vel));
    try std.testing.expect(Ecs.component_count == 2);
    const pos_info = Ecs.componentInfo(Pos);
    try std.testing.expect(pos_info.id == Ecs.componentId(Pos));
    try std.testing.expect(pos_info.size == @sizeOf(Pos));
    try std.testing.expect(pos_info.alignment == @alignOf(Pos));
    try std.testing.expect(std.mem.eql(u8, pos_info.name, @typeName(Pos)));
    try std.testing.expect(Ecs.components[Ecs.componentId(Pos)].id == Ecs.componentId(Pos));
}
test "archetype order does not matter" {
    const Ecs = ECS(.{.{ Pos, Vel }});
    try std.testing.expect(Ecs.archetypeId(&[_]type{ Pos, Vel }) == Ecs.archetypeId(&[_]type{ Vel, Pos }));
    try std.testing.expect(Ecs.archetype_count == 1);
}
test "duplicate archetype sets are deduplicated" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{ Vel, Pos }, .{Pos} });
    try std.testing.expect(Ecs.archetype_count == 2);
    try std.testing.expect(Ecs.component_count == 2);
}
test "archetype data stores and returns components" {
    const Ecs = ECS(.{.{Health}});
    const data = Ecs.storage(&[_]type{Health});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const sample = Ecs.EntityReference{ .id = 0, .gen = 0 };
    const index: u32 = try data.add(allocator, &sample);
    try std.testing.expect(index == 0);
    try std.testing.expect(data.count() == 1);
    const health_mut: *Health = try data.get(Health, 0);
    health_mut.current_value = 42;
    const health: *const Health = try data.get(Health, 0);
    try std.testing.expect(health.current_value == 42);
}
test "entity create destroy and slot reuse" {
    const Ecs = ECS(.{.{ Pos, Vel }});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    try std.testing.expect(created.exists());
    try std.testing.expect(created.isAlive());
    try std.testing.expect(created.state() == .none);
    try std.testing.expect(Ecs.count(&[_]type{ Pos, Vel }) == 1);
    const data = Ecs.storage(&[_]type{ Pos, Vel });
    const row = try created.indexOf();
    const pos: *Pos = try data.get(Pos, row);
    pos.horizontal_coordinate = 10;
    try created.destroy(allocator);
    try std.testing.expect(created.exists());
    try std.testing.expect(!created.isAlive());
    try std.testing.expect(Ecs.count(&[_]type{ Pos, Vel }) == 0);
    try std.testing.expectError(
        Ecs.EcsError.EntityIsNotAlive,
        created.destroy(allocator),
    );
    const recycled = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    try std.testing.expect(recycled.id == created.id);
    try std.testing.expect(recycled.gen == created.gen +% 1);
    try std.testing.expect(recycled.isAlive());
    try std.testing.expect(recycled.state() == .none);
}
test "entity migrate copies shared components" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{ Pos, Health } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    const source_data = Ecs.storage(&[_]type{ Pos, Vel });
    (try source_data.get(Pos, 0)).horizontal_coordinate = 7;
    (try source_data.get(Vel, 0)).horizontal_speed = 1.5;
    const migrated = try created.migrate(allocator, &[_]type{ Pos, Health }, true);
    try std.testing.expect(migrated.isAlive());
    try std.testing.expect(migrated.state() == .none);
    try std.testing.expect(!created.isAlive());
    try std.testing.expect(try migrated.archetypeOf() == Ecs.archetypeId(&[_]type{ Pos, Health }));
    try std.testing.expect(Ecs.count(&[_]type{ Pos, Vel }) == 0);
    try std.testing.expect(Ecs.count(&[_]type{ Pos, Health }) == 1);
    const dest_data = Ecs.storage(&[_]type{ Pos, Health });
    const moved: *const Pos = try dest_data.get(Pos, 0);
    try std.testing.expect(moved.horizontal_coordinate == 7);
}
test "supersets and component archetype lists are precomputed" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const small_id = Ecs.archetypeId(&[_]type{Pos});
    const big_id = Ecs.archetypeId(&[_]type{ Pos, Vel });
    try std.testing.expect(Ecs.archetypes[small_id].superset_ids.len == 1);
    try std.testing.expect(Ecs.archetypes[small_id].superset_ids[0] == big_id);
    try std.testing.expect(Ecs.archetypes[big_id].superset_ids.len == 0);
    const pos_id = Ecs.componentId(Pos);
    const vel_id = Ecs.componentId(Vel);
    try std.testing.expect(Ecs.components[pos_id].archetype_ids.len == 2);
    try std.testing.expect(Ecs.components[vel_id].archetype_ids.len == 1);
    try std.testing.expect(Ecs.hasComponent(small_id, pos_id));
    try std.testing.expect(!Ecs.hasComponent(small_id, vel_id));
    try std.testing.expect(Ecs.columnOf(big_id, vel_id) != null);
    try std.testing.expect(Ecs.columnOf(small_id, vel_id) == null);
}
test "handler page returns the exact archetype" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel }, .{ Pos, Vel, Health } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };

    const page = handler.page(&[_]type{ Pos, Vel });
    try std.testing.expect(page.archetypeInfo().component_ids.len == 2);
    try std.testing.expect(page.get(Pos).len == 0);
    _ = page.entities();
}
test "handler pages match supersets and honor exclude" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel }, .{ Pos, Vel, Health } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };

    var all_iterator = handler.pages(&[_]type{ Pos, Vel }, null);
    var all_count: usize = 0;
    while (all_iterator.next()) |page| {
        all_count += 1;
        _ = page.get(Pos);
        _ = page.entities();
    }
    try std.testing.expect(all_count == 2);

    var filtered_iterator = handler.pages(&[_]type{Pos}, &[_]type{Vel});
    var filtered_count: usize = 0;
    while (filtered_iterator.next()) |page| {
        filtered_count += 1;
        try std.testing.expect(page.archetypeInfo().component_ids.len == 1);
    }
    try std.testing.expect(filtered_count == 1);

    var null_iterator = handler.pages(&[_]type{Pos}, null);
    var null_count: usize = 0;
    while (null_iterator.next()) |_| {
        null_count += 1;
    }
    try std.testing.expect(null_count == 3);

    var empty_iterator = handler.pages(&[_]type{Pos}, &[_]type{});
    var empty_count: usize = 0;
    while (empty_iterator.next()) |_| {
        empty_count += 1;
    }
    try std.testing.expect(empty_count == 3);

    try std.testing.expect(handler.count(&[_]type{Pos}, null) == 0);
}
test "page get returns mutable column and mutates data" {
    const Ecs = ECS(.{.{ Pos, Vel }});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    _ = created;
    const handler = Ecs.SystemHandler{ .allocator = allocator };

    var iterator = handler.pages(&[_]type{ Pos, Vel }, null);
    var found_page: bool = false;
    while (iterator.next()) |page| {
        found_page = true;
        const positions = page.get(Pos);
        try std.testing.expect(positions.len == 1);
        positions[0].horizontal_coordinate = 77;
        const velocities = page.get(Vel);
        velocities[0].horizontal_speed = 3.5;
    }
    try std.testing.expect(found_page);

    const data = Ecs.storage(&[_]type{ Pos, Vel });
    const pos: *const Pos = try data.get(Pos, 0);
    try std.testing.expect(pos.horizontal_coordinate == 77);
    const vel: *const Vel = try data.get(Vel, 0);
    try std.testing.expect(vel.horizontal_speed == 3.5);
}
test "nested tuples flatten into component sets" {
    const Transform = .{ Pos, Vel };
    const Ecs = ECS(.{ Transform, .{ Transform, Health }, .{Pos} });
    try std.testing.expect(Ecs.component_count == 3);
    try std.testing.expect(Ecs.archetype_count == 3);
    try std.testing.expect(Ecs.archetypeId(Transform) == Ecs.archetypeId(&[_]type{ Pos, Vel }));
    try std.testing.expect(Ecs.archetypeId(&.{ Transform, Health }) == Ecs.archetypeId(&[_]type{ Pos, Vel, Health }));
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const created = try Ecs.create(allocator, Transform);
    _ = created;
    try std.testing.expect(Ecs.count(Transform) == 1);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    var iterator = handler.pages(Transform, null);
    var matched: usize = 0;
    while (iterator.next()) |_| {
        matched += 1;
    }
    try std.testing.expect(matched == 2);
}
test "entity reference refreshes after migrate" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    try std.testing.expect(created.exists());
    try std.testing.expect(created.isAlive());

    const refreshed = created.entity().?;
    try std.testing.expect(refreshed.gen == created.gen);

    const moved = try created.migrate(allocator, &[_]type{Pos}, true);
    try std.testing.expect(moved.isAlive());
    try std.testing.expect(try moved.archetypeOf() == Ecs.archetypeId(&[_]type{Pos}));
    try std.testing.expect(!created.isAlive());
    try std.testing.expect(created.entity() == null);
    // Fresh handle rebuilt from the SoA generation column is alive.
    const fresh = Ecs.EntityReference{
        .id = created.id,
        .gen = Ecs.entity_generation.items[created.id],
    };
    try std.testing.expect(fresh.isAlive());
    try std.testing.expect(fresh.gen == moved.gen);

    try fresh.destroy(allocator);
    try std.testing.expect(!fresh.isAlive());
    try std.testing.expect(fresh.exists());
    try std.testing.expect(fresh.entity() == null);
}
test "handler getComponent accesses a specific row" {
    const Ecs = ECS(.{.{ Pos, Vel }});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });

    const pos_mut: *Pos = try handler.getComponent(created, Pos);
    pos_mut.horizontal_coordinate = 123;
    const pos_const: *const Pos = try handler.getComponent(created, Pos);
    try std.testing.expect(pos_const.horizontal_coordinate == 123);

    const vel: *const Vel = try handler.getComponent(created, Vel);
    try std.testing.expect(vel.horizontal_speed == 0.0);

    try std.testing.expectError(
        Ecs.EcsError.ComponentNotFoundInArchetype,
        handler.getComponent(created, Health),
    );

    try created.destroy(allocator);
    try std.testing.expectError(
        Ecs.EcsError.EntityIsNotAlive,
        handler.getComponent(created, Pos),
    );
}
test "schedule runs systems in order and applies commands between them" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const S = struct {
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 2,
            }});
        }
        fn check_and_spawn(h: *Ecs.SystemHandler) anyerror!void {
            // Spawned by the previous system, flushed before this one.
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
            try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 4,
            }});
            // Queued, not yet visible.
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 2);
            var it = h.pages(&[_]type{Pos}, null);
            var sum: i32 = 0;
            while (it.next()) |page| {
                for (page.get(Pos)) |*pos| {
                    sum += pos.horizontal_coordinate;
                }
            }
            try std.testing.expect(sum == 4);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.check_and_spawn, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
    try std.testing.expect(Ecs.count(&[_]type{Pos}) == 2);
}
test "deferred migrate rejects a second queued command" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });
    const S = struct {
        fn setup(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 9, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn move_and_kill(h: *Ecs.SystemHandler) anyerror!void {
            var it = h.pages(&[_]type{ Pos, Vel }, null);
            var target: ?Ecs.EntityReference = null;
            while (it.next()) |page| {
                for (page.entities()) |ref| {
                    if (target == null) {
                        target = ref;
                    }
                }
            }
            const ref = target.?;
            try h.cmdMigrate(ref, &[_]type{Pos}, true);
            try std.testing.expect(ref.state() == .pending_migrate);
            // Same slot destroyed right after: rejected at queue time,
            // so a migrate-pending entity can never become destroy-pending.
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdDestroy(ref),
            );
            // Duplicate migrate is rejected as well.
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdMigrate(ref, &[_]type{Pos}, true),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{ Pos, Vel }, null) == 0);
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
            var it = h.pages(&[_]type{Pos}, null);
            var found = false;
            while (it.next()) |page| {
                for (page.get(Pos)) |*pos| {
                    try std.testing.expect(pos.horizontal_coordinate == 9);
                    found = true;
                }
                for (page.entities()) |ref| {
                    try std.testing.expect(ref.state() == .none);
                }
            }
            try std.testing.expect(found);
        }
    };
    const App = Ecs.Schedule(.{ S.setup, S.move_and_kill, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "pending flags are cleared when a failing system discards commands" {
    const Ecs = ECS(.{.{Pos}});
    const CustomError = error{Boom};
    const S = struct {
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 1,
            }});
        }
        fn queue_then_fail(h: *Ecs.SystemHandler) anyerror!void {
            var it = h.pages(&[_]type{Pos}, null);
            var target: ?Ecs.EntityReference = null;
            while (it.next()) |page| {
                for (page.entities()) |ref| {
                    target = ref;
                }
            }
            try h.cmdDestroy(target.?);
            try std.testing.expect(target.?.state() == .pending_destroy);
            return CustomError.Boom;
        }
        fn retry_destroy(h: *Ecs.SystemHandler) anyerror!void {
            // Discard above must have reset the flag, so queueing works again.
            var it = h.pages(&[_]type{Pos}, null);
            var target: ?Ecs.EntityReference = null;
            while (it.next()) |page| {
                for (page.entities()) |ref| {
                    target = ref;
                }
            }
            try h.cmdDestroy(target.?);
        }
        fn verify_empty(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 0);
        }
    };
    const Failing = Ecs.Schedule(.{ S.spawn, S.queue_then_fail });
    const Recovery = Ecs.Schedule(.{ S.retry_destroy, S.verify_empty });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try std.testing.expectError(CustomError.Boom, Failing.run(allocator));
    try std.testing.expect(Ecs.count(&[_]type{Pos}) == 1);
    try Recovery.run(allocator);
}
test "entity states are densely packed four per byte" {
    const Ecs = ECS(.{.{Pos}});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    var refs: [5]Ecs.EntityReference = undefined;
    for (0..5) |i| {
        refs[i] = try Ecs.create(allocator, &[_]type{Pos});
    }
    // 5 slots fit into 2 bytes.
    try std.testing.expect(Ecs.entity_state_words.items.len == 2);
    // Setting one slot must not clobber its neighbours in the same byte.
    Ecs.setEntityState(refs[1].id, .pending_destroy);
    Ecs.setEntityState(refs[2].id, .pending_migrate);
    try std.testing.expect(Ecs.getEntityState(refs[0].id) == .none);
    try std.testing.expect(Ecs.getEntityState(refs[1].id) == .pending_destroy);
    try std.testing.expect(Ecs.getEntityState(refs[2].id) == .pending_migrate);
    try std.testing.expect(Ecs.getEntityState(refs[3].id) == .none);
    try std.testing.expect(Ecs.getEntityState(refs[4].id) == .none);
    try std.testing.expect(refs[1].state() == .pending_destroy);
    Ecs.clearPending(refs[1].id);
    Ecs.clearPending(refs[2].id);
    try std.testing.expect(refs[1].state() == .none);
    try std.testing.expect(Ecs.entity_state_words.items[0] == 0);
}
test "bulk commands create and destroy pages" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const S = struct {
        fn spawn_many(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 6,
            }}, 3);
            try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 7, .vertical_coordinate = 8 },
                Vel{ .horizontal_speed = 1, .vertical_speed = 2 },
            });
        }
        fn wipe_small(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 4);
            try h.cmdDestroyPages(&[_]type{Pos}, &[_]type{Vel});
        }
        fn wipe_rest(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
            try h.cmdDestroyPage(&[_]type{ Pos, Vel });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn_many, S.wipe_small, S.wipe_rest, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "failing system discards its commands and propagates anyerror" {
    const Ecs = ECS(.{.{Pos}});
    const CustomError = error{Boom};
    const S = struct {
        fn ok_spawn(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 1,
            }});
        }
        fn failing(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 2,
            }});
            return CustomError.Boom;
        }
    };
    const App = Ecs.Schedule(.{ S.ok_spawn, S.failing });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try std.testing.expectError(CustomError.Boom, App.run(allocator));
    // First system applied, failing system's command discarded.
    try std.testing.expect(Ecs.count(&[_]type{Pos}) == 1);
    // Scheduler is reusable after a failure.
    const Clean = Ecs.Schedule(.{S.ok_spawn});
    try Clean.run(allocator);
    try std.testing.expect(Ecs.count(&[_]type{Pos}) == 2);
}
