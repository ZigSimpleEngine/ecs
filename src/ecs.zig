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
/// All metadata (`components`, `archetypes` and per-component archetype lists)
/// is precomputed once in comptime and immutable.
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
            /// Entity already has a queued destroy or migrate or reparent in this batch.
            EntityHasPendingCommand,
            /// Requested position lies outside the storage range.
            IndexOutOfBounds,
            /// Requested component is not stored in this archetype.
            ComponentNotFoundInArchetype,
            /// Reparenting would create a cycle in the hierarchy.
            HierarchyCycle,
            /// No event of this type is registered for the entity.
            EventNotFound,
            /// A destroy command is already queued for this event in this batch.
            EventHasPendingCommand,
            /// Parallel slices passed to a batch command have different lengths.
            CountMismatch,
            /// No attribute of this type is stored for the entity.
            AttributeNotFound,
            /// A destroy command is already queued for this attribute in this batch.
            AttributeHasPendingCommand,
        };
        /// Sentinel slot id meaning "no entity": no parent, no children, no siblings.
        /// Real entity ids are `u24`, so this never collides with a live slot.
        const NO_ENTITY: u32 = std.math.maxInt(u32);
        /// Contiguous run of rows inside one archetype storage that share the
        /// same hierarchy depth. `depth_zones` lists are sorted ascending by
        /// `depth` and their regions tile the row array without gaps, so a row
        /// at position `p` belongs to the zone with the largest
        /// `offset <= p`. Rows inside a zone have no meaningful order.
        pub const DepthZone = struct {
            /// Hierarchy depth shared by every row in the zone.
            depth: u32,
            /// First row index of the zone inside the storage row array.
            offset: u32,
            /// Number of rows in the zone.
            len: u32,
        };
        /// Locates the zone whose region contains the given row index.
        /// Zones are contiguous, so this is the last zone with
        /// `offset <= index`. Shared by component storages and attribute
        /// pages: the algorithm only sees the zone descriptors.
        /// - `zones` - depth zones sorted ascending by depth, tiling rows.
        /// - `pos` - row position.
        ///
        /// Returns `usize` - index into `zones`.
        fn zoneIndexForOffset(zones: []const DepthZone, pos: u32) usize {
            var lo: usize = 0;
            var hi: usize = zones.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (zones[mid].offset <= pos) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo - 1;
        }
        /// Finds the sorted insertion point of a depth in a zone list.
        /// Shared by component storages and attribute pages.
        /// - `zones` - depth zones sorted ascending by depth.
        /// - `depth` - hierarchy depth.
        ///
        /// Returns `usize` - first zone with `depth >= depth`.
        fn zoneInsertPosition(zones: []const DepthZone, depth: u32) usize {
            var lo: usize = 0;
            var hi: usize = zones.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (zones[mid].depth < depth) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }
        /// Deferred lifecycle state of an entity slot: one boolean per kind
        /// of pending command. Stored as a 1-byte packed struct per slot, so
        /// adding a new kind only requires a new field - no repacking.
        /// `pending_create` marks a slot reserved by a queued create command:
        /// the entity is not alive yet but its id is already taken.
        pub const EntityState = packed struct {
            /// Queued destroy, applied at the next flush.
            pending_destroy: bool = false,
            /// Queued migrate, applied at the next flush.
            pending_migrate: bool = false,
            /// Queued reparent, applied at the next flush.
            pending_reparent: bool = false,
            /// Slot reserved by a queued create; the entity becomes alive
            /// only when the command flushes.
            pending_create: bool = false,
            /// Checks whether no command is queued for the slot.
            /// - `self` - state to inspect.
            ///
            /// Returns `bool` - true when every flag is clear.
            pub fn isIdle(self: @This()) bool {
                return !self.pending_destroy and
                    !self.pending_migrate and
                    !self.pending_reparent and
                    !self.pending_create;
            }
        };
        /// One reserved entity slot: the future handle plus whether the id
        /// came from the free list (so discard can decide between pushing the
        /// id back or popping the appended slot arrays).
        const Reservation = struct {
            ref: EntityReference,
            from_free: bool,
        };
        /// Read-only iterator over the children of one entity. Produced by
        /// `EntityReference.children`. Walks the sibling linked list; the
        /// list itself is immutable from the outside.
        pub const ChildrenIterator = struct {
            current: u32,
            /// Yields the next child, or null when the list is exhausted.
            /// - `self` - iterator to advance.
            ///
            /// Returns `?EntityReference` - next child handle.
            pub fn next(self: *ChildrenIterator) ?EntityReference {
                if (self.current == NO_ENTITY) {
                    return null;
                }
                const id = self.current;
                self.current = Ecs.entity_next_sibling.items[id];
                return EntityReference{
                    .id = @intCast(id),
                    .gen = Ecs.entity_generation.items[id],
                };
            }
        };
        /// Read-only iterator over the whole subtree below one entity, in
        /// pre-order (children before grandchildren), excluding the root.
        /// Produced by `EntityReference.descendants`. Zero allocation: the
        /// walk descends via `first_child` and climbs via `parent` when a
        /// branch ends, so no stack buffer is needed.
        pub const DescendantsIterator = struct {
            root: u32,
            current: u32,
            /// Yields the next descendant, or null when the subtree is done.
            /// - `self` - iterator to advance.
            ///
            /// Returns `?EntityReference` - next descendant handle.
            pub fn next(self: *DescendantsIterator) ?EntityReference {
                if (self.current == NO_ENTITY) {
                    return null;
                }
                const id = self.current;
                if (Ecs.entity_first_child.items[id] != NO_ENTITY) {
                    self.current = Ecs.entity_first_child.items[id];
                } else {
                    var cur: u32 = id;
                    while (cur != NO_ENTITY and
                        cur != self.root and
                        Ecs.entity_next_sibling.items[cur] == NO_ENTITY)
                    {
                        cur = Ecs.entity_parent.items[cur];
                    }
                    if (cur == NO_ENTITY or cur == self.root) {
                        self.current = NO_ENTITY;
                    } else {
                        self.current = Ecs.entity_next_sibling.items[cur];
                    }
                }
                return EntityReference{
                    .id = @intCast(id),
                    .gen = Ecs.entity_generation.items[id],
                };
            }
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
            /// A slot reserved by a queued create (`pending_create`) is not
            /// alive yet even though its id and generation are already taken.
            /// - `self` - reference to inspect.
            ///
            /// Returns `bool` - true when the slot exists, generations match
            /// and no create command is still pending for it.
            pub fn isAlive(self: *const EntityReference) bool {
                if (!self.exists()) {
                    return false;
                }
                const entity_index: u32 = self.id;
                if (Ecs.entity_generation.items[entity_index] != self.gen) {
                    return false;
                }
                return !Ecs.getEntityState(entity_index).pending_create;
            }
            /// Returns the pending lifecycle state of the referenced slot.
            /// - `self` - reference to inspect.
            ///
            /// Returns `EntityState` - queued state, or idle when the id was
            /// never assigned.
            pub fn state(self: *const EntityReference) EntityState {
                const entity_index: u32 = self.id;
                if (entity_index >= Ecs.entityStateLen()) {
                    return .{};
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
            /// Returns the parent of the entity, or null when it is detached
            /// (a root). Read-only: parents change only through deferred
            /// commands.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `?EntityReference` - live parent handle, or null.
            pub fn parent(self: *const EntityReference) ?EntityReference {
                if (!self.isAlive()) {
                    return null;
                }
                const pid = Ecs.entity_parent.items[self.id];
                if (pid == NO_ENTITY) {
                    return null;
                }
                return EntityReference{
                    .id = @intCast(pid),
                    .gen = Ecs.entity_generation.items[pid],
                };
            }
            /// Returns the hierarchy depth of the entity. Detached entities
            /// have depth zero; a child always has `depthOf == depthOf(parent) + 1`.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `u32` - depth of the entity.
            pub fn depthOf(self: *const EntityReference) EcsError!u32 {
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                return Ecs.entity_depth.items[self.id];
            }
            /// Returns the first child of the entity, or null when it has none.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `?EntityReference` - live child handle, or null.
            pub fn firstChild(self: *const EntityReference) ?EntityReference {
                if (!self.isAlive()) {
                    return null;
                }
                const cid = Ecs.entity_first_child.items[self.id];
                if (cid == NO_ENTITY) {
                    return null;
                }
                return EntityReference{
                    .id = @intCast(cid),
                    .gen = Ecs.entity_generation.items[cid],
                };
            }
            /// Returns the next sibling of the entity, or null when it is the
            /// last child of its parent.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `?EntityReference` - live sibling handle, or null.
            pub fn nextSibling(self: *const EntityReference) ?EntityReference {
                if (!self.isAlive()) {
                    return null;
                }
                const sid = Ecs.entity_next_sibling.items[self.id];
                if (sid == NO_ENTITY) {
                    return null;
                }
                return EntityReference{
                    .id = @intCast(sid),
                    .gen = Ecs.entity_generation.items[sid],
                };
            }
            /// Returns the previous sibling of the entity, or null when it is
            /// the first child of its parent.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `?EntityReference` - live sibling handle, or null.
            pub fn prevSibling(self: *const EntityReference) ?EntityReference {
                if (!self.isAlive()) {
                    return null;
                }
                const sid = Ecs.entity_prev_sibling.items[self.id];
                if (sid == NO_ENTITY) {
                    return null;
                }
                return EntityReference{
                    .id = @intCast(sid),
                    .gen = Ecs.entity_generation.items[sid],
                };
            }
            /// Counts the direct children of the entity.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `u32` - number of children.
            pub fn childCount(self: *const EntityReference) EcsError!u32 {
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                var total: u32 = 0;
                var child = Ecs.entity_first_child.items[self.id];
                while (child != NO_ENTITY) : (child = Ecs.entity_next_sibling.items[child]) {
                    total += 1;
                }
                return total;
            }
            /// Checks whether the entity lies somewhere below the given
            /// ancestor. The check is strict: a node is not its own ancestor.
            /// - `self` - reference to inspect. Must be alive.
            /// - `ancestor` - candidate ancestor. Must be alive.
            ///
            /// Returns `bool` - true when `ancestor` is an ancestor of `self`.
            pub fn isDescendantOf(self: *const EntityReference, ancestor: EntityReference) bool {
                if (!self.isAlive() or !ancestor.isAlive()) {
                    return false;
                }
                var cur = Ecs.entity_parent.items[self.id];
                while (cur != NO_ENTITY) {
                    if (cur == ancestor.id) {
                        return true;
                    }
                    cur = Ecs.entity_parent.items[cur];
                }
                return false;
            }
            /// Returns a read-only iterator over the direct children of the
            /// entity. The iterator observes live hierarchy data; children
            /// can only be added or removed through deferred commands.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `ChildrenIterator` - zero-cost walk over the sibling list.
            pub fn children(self: *const EntityReference) ChildrenIterator {
                if (!self.isAlive()) {
                    return ChildrenIterator{ .current = NO_ENTITY };
                }
                return ChildrenIterator{ .current = Ecs.entity_first_child.items[self.id] };
            }
            /// Returns a read-only iterator over the subtree below the entity
            /// (pre-order, excluding the entity itself). Zero allocation.
            /// - `self` - reference to inspect. Must be alive.
            ///
            /// Returns `DescendantsIterator` - walk over the subtree.
            pub fn descendants(self: *const EntityReference) DescendantsIterator {
                if (!self.isAlive()) {
                    return DescendantsIterator{ .root = NO_ENTITY, .current = NO_ENTITY };
                }
                return DescendantsIterator{
                    .root = self.id,
                    .current = Ecs.entity_first_child.items[self.id],
                };
            }
            /// Destroys the referenced entity and its whole subtree, then
            /// recycles every slot. Immediate variant used by command
            /// flushing; clears any pending state left by queueing commands.
            /// Children are destroyed before their parent (via a collected
            /// pre-order list walked in reverse), so sibling links remain
            /// valid during the walk. Iterative: no recursion on deep trees.
            /// - `self` - reference to destroy. Must be alive.
            /// - `allocator` - funds the free-slot bookkeeping.
            fn destroy(self: *const EntityReference, allocator: std.mem.Allocator) EcsError!void {
                @setEvalBranchQuota(10_000_000);
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                var order: std.ArrayListUnmanaged(u32) = .empty;
                defer order.deinit(allocator);
                try order.append(allocator, self.id);
                var idx: usize = 0;
                while (idx < order.items.len) : (idx += 1) {
                    var child = Ecs.entity_first_child.items[order.items[idx]];
                    while (child != NO_ENTITY) : (child = Ecs.entity_next_sibling.items[child]) {
                        try order.append(allocator, child);
                    }
                }
                std.mem.reverse(u32, order.items);
                for (order.items) |id| {
                    try Ecs.destroyNode(id, allocator);
                }
            }
            /// Moves the entity under a new parent, or detaches it when
            /// `new_parent_id` is `NO_ENTITY`. Recomputes the depth of the
            /// whole subtree and relocates rows to their new depth zone
            /// inside the owning archetype. Immediate variant used by command
            /// flushing; the queued command carries the pending-parent id.
            /// Private: structural changes run only via commands flushed by
            /// the scheduler.
            /// - `self` - reference to move. Must be alive.
            /// - `allocator` - funds the subtree walk.
            /// - `new_parent_id` - new parent slot id, or `NO_ENTITY` to detach.
            fn reparentById(
                self: *const EntityReference,
                allocator: std.mem.Allocator,
                new_parent_id: u32,
            ) EcsError!void {
                @setEvalBranchQuota(10_000_000);
                if (!self.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                const old_parent_id: u32 = Ecs.entity_parent.items[entity_index];
                if (new_parent_id != NO_ENTITY) {
                    if (new_parent_id == entity_index) {
                        return EcsError.HierarchyCycle;
                    }
                    // Safety net: command-time validation already rejected
                    // batch cycles, but a flush-time walk is cheap and keeps
                    // the invariant even if validation changes later.
                    var cur = new_parent_id;
                    while (cur != NO_ENTITY) {
                        if (cur == entity_index) {
                            return EcsError.HierarchyCycle;
                        }
                        cur = Ecs.entity_parent.items[cur];
                    }
                }
                const old_depth: u32 = Ecs.entity_depth.items[entity_index];
                const new_depth: u32 = if (new_parent_id == NO_ENTITY)
                    0
                else
                    Ecs.entity_depth.items[new_parent_id] + 1;
                const delta: i64 = @as(i64, new_depth) - @as(i64, old_depth);
                Ecs.unlinkFromParent(entity_index);
                if (new_parent_id != NO_ENTITY) {
                    Ecs.linkChild(entity_index, new_parent_id);
                }
                // Parent change files Reparent (same-parent reorderings are
                // silent); depth changes file DepthUpdate per member below,
                // including the root itself.
                if (old_parent_id != new_parent_id) {
                    const old_parent: ?EntityReference = if (old_parent_id == NO_ENTITY)
                        null
                    else
                        EntityReference{
                            .id = @intCast(old_parent_id),
                            .gen = Ecs.entity_generation.items[old_parent_id],
                        };
                    const new_parent: ?EntityReference = if (new_parent_id == NO_ENTITY)
                        null
                    else
                        EntityReference{
                            .id = @intCast(new_parent_id),
                            .gen = Ecs.entity_generation.items[new_parent_id],
                        };
                    try EventStore(Reparent).fileLifecycle(
                        allocator,
                        Ecs.entity_archetype.items[entity_index],
                        self.*,
                        .{ .old_parent = old_parent, .new_parent = new_parent },
                    );
                }
                if (delta == 0) {
                    return;
                }
                // Depth changed: update every subtree member and move its row
                // into the zone matching its new depth. Hierarchy links are
                // untouched by row moves, so a single pre-order pass suffices.
                var order: std.ArrayListUnmanaged(u32) = .empty;
                defer order.deinit(allocator);
                try order.append(allocator, entity_index);
                var idx: usize = 0;
                while (idx < order.items.len) : (idx += 1) {
                    var child = Ecs.entity_first_child.items[order.items[idx]];
                    while (child != NO_ENTITY) : (child = Ecs.entity_next_sibling.items[child]) {
                        try order.append(allocator, child);
                    }
                }
                for (order.items) |id| {
                    const next_depth: u32 = @intCast(@as(i64, Ecs.entity_depth.items[id]) + delta);
                    Ecs.entity_depth.items[id] = next_depth;
                    // Attribute rows ride along into the new depth zone.
                    try Ecs.notifyAttributeDepthChanged(id, next_depth, allocator);
                    // Every moved member files DepthUpdate, the reparented
                    // root included: one entity may carry both Reparent and
                    // DepthUpdate records.
                    const member = EntityReference{
                        .id = @intCast(id),
                        .gen = Ecs.entity_generation.items[id],
                    };
                    try EventStore(DepthUpdate).fileLifecycle(
                        allocator,
                        Ecs.entity_archetype.items[id],
                        member,
                        .{
                            .old_depth = @intCast(@as(i64, next_depth) - delta),
                            .new_depth = next_depth,
                        },
                    );
                    const arch: u32 = Ecs.entity_archetype.items[id];
                    const row: u32 = Ecs.entity_row.items[id];
                    const ref = EntityReference{
                        .id = @intCast(id),
                        .gen = Ecs.entity_generation.items[id],
                    };
                    Ecs.storages[arch].removeRow(row);
                    _ = try Ecs.storages[arch].insertRowAtDepth(allocator, &ref, next_depth);
                }
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
                @setEvalBranchQuota(10_000_000);
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
                // Events follow the entity: relocate them before the storage
                // surgery, so an allocation failure leaves the entity untouched.
                // Attributes relocate the same way.
                try Ecs.notifyEventEntityMigrated(entity_index, source_id, dest_id, next.gen, allocator);
                try Ecs.notifyAttributeMigrated(entity_index, source_id, dest_id, next.gen, allocator);
                // Hierarchy survives a migrate: the row keeps its depth and
                // lands in the matching zone of the destination archetype.
                const depth: u32 = Ecs.entity_depth.items[entity_index];
                const dest_index: u32 = blk: {
                    const idx = try Ecs.storages[dest_id].insertRowAtDepth(allocator, &next, depth);
                    if (Ecs.storages[dest_id].count() == 1) {
                        Ecs.setArchetypeNonEmpty(dest_id);
                    }
                    break :blk idx;
                };
                if (copy) {
                    Ecs.copyShared(
                        source_id,
                        source_index,
                        dest_id,
                        dest_index,
                    );
                }
                Ecs.storages[source_id].removeRow(source_index);
                if (Ecs.storages[source_id].count() == 0) {
                    Ecs.clearArchetypeNonEmpty(source_id);
                }
                Ecs.entity_generation.items[entity_index] = next.gen;
                Ecs.entity_archetype.items[entity_index] = dest_id;
                Ecs.entity_row.items[entity_index] = dest_index;
                Ecs.setEntityState(entity_index, .{});
                if (source_id != dest_id) {
                    try EventStore(Migrate).fileLifecycle(allocator, dest_id, next, .{
                        .from = source_id,
                        .to = dest_id,
                    });
                }
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
            @setEvalBranchQuota(10_000_000);
            if (input_count == 0) {
                @compileError("ECS needs at least one archetype.");
            }
            var biggest: usize = 0;
            for (0..input_count) |i| {
                const inner_info = @typeInfo(@TypeOf(sets[i]));
                if (inner_info != .@"struct" or !inner_info.@"struct".is_tuple) {
                    @compileError("Each archetype must be a tuple of component types; tuples may be nested.");
                }
                // Cheap leaf count only; the full flatten happens once in Tables.
                const leaf_count = countLeafTypes(sets[i]);
                if (leaf_count > biggest) {
                    biggest = leaf_count;
                }
            }
            const Keep = struct {
                const value: usize = biggest;
            };
            break :blk Keep.value;
        };
        /// Every comptime table: canonical types, deduplicated archetypes, components
        /// and component->archetype links. Frozen once, read-only after.
        const Tables = blk: {
            @setEvalBranchQuota(10_000_000);
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
                sortTypesByName(max_len, &uniq, total);
                canon_types[i] = uniq;
                canon_lens[i] = total;
            }
            // Hash-bucketed dedup: sort input indices by set hash, compare
            // exactly only inside equal-hash runs, emit in first-seen order
            // so archetype ids stay stable. O(I log I) instead of O(I^2).
            var order: [input_count]HashIndex = undefined;
            for (0..input_count) |i| {
                order[i] = .{
                    .hash = hashTypeSet(canon_types[i][0..canon_lens[i]]),
                    .index = i,
                };
            }
            var order_scratch: [input_count]HashIndex = undefined;
            sortHashIndices(order[0..], order_scratch[0..]);
            var is_dup: [input_count]bool = [_]bool{false} ** input_count;
            var run: usize = 0;
            while (run < input_count) {
                var run_end: usize = run + 1;
                while (run_end < input_count and order[run_end].hash == order[run].hash) : (run_end += 1) {}
                var k: usize = run + 1;
                while (k < run_end) : (k += 1) {
                    const ki: usize = order[k].index;
                    var m: usize = run;
                    var same: bool = false;
                    while (m < k) : (m += 1) {
                        const mi: usize = order[m].index;
                        if (is_dup[mi]) {
                            continue;
                        }
                        if (canon_lens[mi] != canon_lens[ki]) {
                            continue;
                        }
                        var eq: bool = true;
                        for (0..canon_lens[ki]) |t| {
                            if (canon_types[mi][t] != canon_types[ki][t]) {
                                eq = false;
                                break;
                            }
                        }
                        if (eq) {
                            same = true;
                            break;
                        }
                    }
                    is_dup[ki] = same;
                }
                run = run_end;
            }
            var arch_types: [input_count][max_len]type = undefined;
            var arch_lens: [input_count]usize = [_]usize{0} ** input_count;
            var uniq_count: usize = 0;
            for (0..input_count) |i| {
                if (is_dup[i]) {
                    continue;
                }
                arch_types[uniq_count] = canon_types[i];
                arch_lens[uniq_count] = canon_lens[i];
                uniq_count += 1;
            }
            var comp_types: [input_count * max_len]type = undefined;
            var comp_count: usize = 0;
            for (0..uniq_count) |a| {
                for (arch_types[a][0..arch_lens[a]]) |T| {
                    var seen: bool = false;
                    for (comp_types[0..comp_count]) |C| {
                        if (C == T) {
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
            sortTypesByName(input_count * max_len, &comp_types, comp_count);
            var arch_comp: [input_count][max_len]u32 = undefined;
            for (0..uniq_count) |a| {
                var prev: u32 = 0;
                for (arch_types[a][0..arch_lens[a]], 0..) |T, k| {
                    const c: u32 = @intCast(componentIndexInSorted(T, comp_types[0..comp_count]).?);
                    // Both sides share the (hash, name) order, so rows stay
                    // ascending; merge-based query checks rely on this.
                    if (k > 0 and prev >= c) {
                        @compileError("arch_comp row is not sorted; merge checks are invalid.");
                    }
                    prev = c;
                    arch_comp[a][k] = c;
                }
            }
            var total_arch_entries: usize = 0;
            for (0..uniq_count) |a| {
                total_arch_entries += arch_lens[a];
            }
            // Set hashes for O(1)-filter exact lookup in archetypeId.
            var arch_hashes: [input_count]u64 = undefined;
            for (0..uniq_count) |a| {
                arch_hashes[a] = hashTypeSet(arch_types[a][0..arch_lens[a]]);
            }
            break :blk .{
                .uniq_count = uniq_count,
                .comp_count = comp_count,
                .arch_types = arch_types,
                .arch_comp = arch_comp,
                .arch_lens = arch_lens,
                .arch_hashes = arch_hashes,
                .comp_types = comp_types,
                .total_arch_entries = total_arch_entries,
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
            @setEvalBranchQuota(10_000_000);
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
        /// Inverted index component -> archetypes, built in two linear passes
        /// over `arch_comp` (count, then fill). Rows are ascending in `a`
        /// because archetypes are visited in order. Backs both
        /// `ComponentInfo.archetype_ids` and rarest-seed query matching.
        /// Flat layout is component-major and contiguous: component `c`
        /// owns `flat[offsets[c]..offsets[c]+lens[c]]`.
        const CompArchetypes = blk: {
            @setEvalBranchQuota(10_000_000);
            var lens: [input_count * max_len]usize = [_]usize{0} ** (input_count * max_len);
            for (0..ARCH_COUNT) |a| {
                for (Tables.arch_comp[a][0..Tables.arch_lens[a]]) |c| {
                    lens[c] += 1;
                }
            }
            var offsets: [input_count * max_len + 1]usize = undefined;
            var acc: usize = 0;
            for (0..component_count) |c| {
                offsets[c] = acc;
                acc += lens[c];
            }
            offsets[component_count] = acc;
            var flat: [input_count * max_len]u32 = undefined;
            var cursors: [input_count * max_len]usize = [_]usize{0} ** (input_count * max_len);
            for (0..component_count) |c| {
                cursors[c] = offsets[c];
            }
            for (0..ARCH_COUNT) |a| {
                for (Tables.arch_comp[a][0..Tables.arch_lens[a]]) |c| {
                    flat[cursors[c]] = @intCast(a);
                    cursors[c] += 1;
                }
            }
            break :blk .{
                .flat = flat,
                .offsets = offsets,
                .lens = lens,
                .total = acc,
            };
        };
        /// Flat component-major archetype index plus per-component lens and
        /// offsets. Each const is its own global so runtime slices
        /// (`ComponentInfo.archetype_ids`, query seeds) can borrow it.
        /// Component `c` owns `comp_arch_flat[comp_arch_off[c]..][0..len]`.
        const comp_arch_flat: [CompArchetypes.total]u32 = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [CompArchetypes.total]u32 = undefined;
            for (0..CompArchetypes.total) |i| {
                out[i] = CompArchetypes.flat[i];
            }
            break :blk out;
        };
        /// Number of archetypes per component, ascending in component id.
        const comp_arch_lens: [component_count]usize = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [component_count]usize = undefined;
            for (0..component_count) |c| {
                out[c] = CompArchetypes.lens[c];
            }
            break :blk out;
        };
        /// Start offsets into `comp_arch_flat` per component, ascending.
        const comp_arch_off: [component_count + 1]usize = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [component_count + 1]usize = undefined;
            for (0..component_count + 1) |c| {
                out[c] = CompArchetypes.offsets[c];
            }
            break :blk out;
        };
        /// Archetype ids of one component, ascending.
        /// - `c` - component id, an index into `components`.
        ///
        /// Returns `[]const u32` - archetype ids containing the component.
        fn archetypesOfComponent(comptime c: usize) []const u32 {
            return comp_arch_flat[comp_arch_off[c]..][0..comp_arch_lens[c]];
        }
        /// Static component descriptors. `components[id].id == id` always holds.
        pub const components: [component_count]ComponentInfo = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [component_count]ComponentInfo = undefined;
            for (0..component_count) |c| {
                const T: type = Tables.comp_types[c];
                out[c] = ComponentInfo{
                    .id = @intCast(c),
                    .size = @sizeOf(T),
                    .alignment = @alignOf(T),
                    .name = @typeName(T),
                    .archetype_ids = archetypesOfComponent(c),
                };
            }
            break :blk out;
        };
        /// Static archetype descriptors. `archetypes[id].id == id` always holds.
        pub const archetypes: [archetype_count]ArchetypeInfo = blk: {
            @setEvalBranchQuota(10_000_000);
            var out: [archetype_count]ArchetypeInfo = undefined;
            var comp_cursor: usize = 0;
            for (0..archetype_count) |a| {
                const comp_len: usize = Tables.arch_lens[a];
                out[a] = ArchetypeInfo{
                    .id = @intCast(a),
                    .component_ids = arch_comp_flat[comp_cursor..][0..comp_len],
                };
                comp_cursor += comp_len;
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
                sortTypesByName(flat_input.len, &uniq, total);
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
            @setEvalBranchQuota(10_000_000);
            const q = comptime canonicalQuery(types);
            const qh: u64 = comptime hashTypeSet(q);
            inline for (0..ARCH_COUNT) |k| {
                if (comptime Tables.arch_hashes[k] != qh) {
                    continue;
                }
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
        /// Maximum component columns in any archetype. Sizes the fixed
        /// `columns` array so every storage has one homogeneous type; the
        /// comptime generation only sets `len` and per-column metadata.
        const MAX_COLS: usize = max_len;
        /// One raw component column: manually managed byte buffer holding
        /// `rows * elem_size` live bytes. The buffer is allocated with the
        /// component alignment via `rawAlloc`/`rawFree`, so `@alignCast` on
        /// access is sound. Zero-size components never allocate; their row
        /// count is implied by `refs` and byte copies are no-ops.
        const Column = struct {
            /// Live bytes, `rows * elem_size`. Alignment-1 view over an
            /// allocation that satisfies `alignment`.
            bytes: []u8 = &[_]u8{},
            /// Allocated capacity in rows.
            cap_rows: usize = 0,
            /// Byte size of one element. Copied from `ComponentInfo.size`.
            elem_size: usize = 0,
            /// Byte alignment of the element. Copied from
            /// `ComponentInfo.alignment`.
            alignment: u29 = 1,
            /// Dense component id. Matches the position of this column in
            /// `archetypes[arch].component_ids`.
            comp_id: u32 = std.math.maxInt(u32),
            /// Ensures room for `need_rows` rows, preserving live bytes.
            /// - `self` - column to grow.
            /// - `allocator` - funds the reallocation.
            /// - `need_rows` - rows that must fit afterwards.
            fn ensureRowCapacity(
                self: *Column,
                allocator: std.mem.Allocator,
                need_rows: usize,
            ) EcsError!void {
                if (need_rows <= self.cap_rows) {
                    return;
                }
                if (self.elem_size == 0) {
                    self.cap_rows = need_rows;
                    return;
                }
                var new_cap: usize = if (self.cap_rows == 0) @max(need_rows, 4) else self.cap_rows * 2;
                while (new_cap < need_rows) {
                    new_cap *= 2;
                }
                const new_nbytes = new_cap * self.elem_size;
                const align_val = std.mem.Alignment.fromByteUnits(self.alignment);
                const new_ptr = allocator.rawAlloc(new_nbytes, align_val, @returnAddress()) orelse
                    return EcsError.OutOfMemory;
                const new_bytes: [*]u8 = new_ptr;
                if (self.bytes.len > 0) {
                    @memcpy(new_bytes[0..self.bytes.len], self.bytes);
                }
                if (self.cap_rows > 0) {
                    const old_cap_bytes = self.cap_rows * self.elem_size;
                    allocator.rawFree(self.bytes.ptr[0..old_cap_bytes], align_val, @returnAddress());
                }
                self.bytes = new_bytes[0..self.bytes.len];
                self.cap_rows = new_cap;
            }
            /// Extends the live length by one row, leaving its bytes undefined.
            /// Caller must have ensured capacity or pass the row count so this
            /// helper can grow. `row_count` is the count before appending.
            fn appendUndefined(
                self: *Column,
                allocator: std.mem.Allocator,
                row_count: usize,
            ) EcsError!void {
                try self.ensureRowCapacity(allocator, row_count + 1);
                if (self.elem_size == 0) {
                    return;
                }
                self.bytes = self.bytes.ptr[0..(row_count + 1) * self.elem_size];
            }
            /// Shrinks the live length by one row. `row_count` is the count
            /// before popping.
            fn popRow(self: *Column, row_count: usize) void {
                if (self.elem_size == 0) {
                    return;
                }
                self.bytes = self.bytes.ptr[0..(row_count - 1) * self.elem_size];
            }
            /// Copies one row inside the column.
            fn copyRow(self: *const Column, src_row: u32, dst_row: u32) void {
                if (self.elem_size == 0) {
                    return;
                }
                const es = self.elem_size;
                @memcpy(
                    @constCast(self.bytes.ptr[dst_row * es ..][0..es]),
                    self.bytes.ptr[src_row * es ..][0..es],
                );
            }
            /// Releases the buffer, keeping the comptime metadata intact.
            fn deinit(self: *Column, allocator: std.mem.Allocator) void {
                if (self.cap_rows > 0 and self.elem_size > 0) {
                    const align_val = std.mem.Alignment.fromByteUnits(self.alignment);
                    allocator.rawFree(
                        self.bytes.ptr[0..self.cap_rows * self.elem_size],
                        align_val,
                        @returnAddress(),
                    );
                }
                self.bytes = &[_]u8{};
                self.cap_rows = 0;
            }
        };
        /// Homogeneous archetype storage. One instance per archetype in
        /// `storages`; only `len` and the `columns` metadata differ. Component
        /// columns are indexed by canonical position (sorted component id),
        /// exactly like the old per-archetype `lists` tuple but type-erased
        /// to bytes. `refs` and `depth_zones` stay typed: they are uniform
        /// across archetypes and have different lengths, so they are not
        /// part of the byte slice.
        const ArchetypeStorage = struct {
            const Self = @This();
            /// One row per stored entity, parallel to the component columns.
            refs: std.ArrayListUnmanaged(EntityReference) = .empty,
            /// Contiguous depth zones tiling the row array. Maintained by
            /// every structural operation, so rows are always grouped by
            /// hierarchy depth: `depth_zones[i]` covers rows
            /// `[offset, offset + len)`.
            depth_zones: std.ArrayListUnmanaged(DepthZone) = .empty,
            /// Fixed backing for component columns; only `columns[0..len]`
            /// is valid. Comptime generation sets `len` and metadata.
            columns: [MAX_COLS]Column = [_]Column{.{}} ** MAX_COLS,
            /// Number of valid entries in `columns`.
            len: usize = 0,
            /// Owning archetype id. Used for debug checks and typed lookup.
            arch: u32 = 0,
            /// Live component columns.
            fn cols(self: *Self) []Column {
                return self.columns[0..self.len];
            }
            /// Live component columns, read-only view.
            fn colsConst(self: *const Self) []const Column {
                return self.columns[0..self.len];
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
            /// Finds the canonical column position of a component id.
            /// - `self` - storage to inspect.
            /// - `comp_id` - component id to locate.
            ///
            /// Returns `?usize` - column index, or null when absent.
            fn columnIndexOfId(self: *const Self, comp_id: u32) ?usize {
                return Ecs.binarySearchIds(
                    Ecs.archetypes[self.arch].component_ids,
                    comp_id,
                );
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
                if (comptime Ecs.componentIndex(Target) == null) {
                    return EcsError.ComponentNotFoundInArchetype;
                }
                const comp_id: u32 = @intCast(comptime Ecs.componentIndex(Target).?);
                const ci = self.columnIndexOfId(comp_id) orelse
                    return EcsError.ComponentNotFoundInArchetype;
                const n: u32 = @intCast(self.refs.items.len);
                if (index >= n) {
                    return EcsError.IndexOutOfBounds;
                }
                if (@sizeOf(Target) == 0) {
                    return @ptrCast(@alignCast(@constCast(self.columns[ci].bytes.ptr)));
                }
                const col = &self.columns[ci];
                std.debug.assert(col.elem_size == @sizeOf(Target));
                const typed: [*]Target = @ptrCast(@alignCast(col.bytes.ptr));
                // Safe: every storage lives in the mutable global
                // `storages` array, so the column is never truly immutable.
                return @constCast(&typed[index]);
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
            /// Locates the zone whose region contains the given row index.
            /// Zones are contiguous, so this is the last zone with
            /// `offset <= index`.
            /// - `self` - storage to inspect.
            /// - `pos` - row position.
            ///
            /// Returns `usize` - index into `depth_zones`.
            fn zoneIndexByOffset(self: *const Self, pos: u32) usize {
                return zoneIndexForOffset(self.depth_zones.items, pos);
            }
            /// Finds the sorted insertion point of a depth in `depth_zones`.
            /// - `self` - storage to inspect.
            /// - `depth` - hierarchy depth.
            ///
            /// Returns `usize` - first zone with `depth >= depth`.
            fn zoneInsertionIndex(self: *const Self, depth: u32) usize {
                return zoneInsertPosition(self.depth_zones.items, depth);
            }
            /// Appends an empty raw row (columns plus reference) without
            /// touching depth zones. Used by bulk creation, which re-sorts
            /// the zones afterwards in one consolidation pass, and by
            /// low-level tests.
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
                const row_count: usize = self.refs.items.len;
                for (self.cols()) |*col| {
                    try col.appendUndefined(allocator, row_count);
                }
                try self.refs.append(allocator, reference.*);
                return @intCast(self.refs.items.len - 1);
            }
            /// Appends a row and places it into the zone matching
            /// `depth`, keeping every zone contiguous and ordered.
            /// The row lands at the end of its zone; deeper zones then
            /// shift by one slot, which costs exactly one moved row per
            /// deeper zone (order inside a zone is irrelevant, so the
            /// rotation moves only boundary elements). Updates
            /// `entity_row` for every relocated row.
            /// - `self` - storage to mutate.
            /// - `allocator` - funds row and zone-list allocation.
            /// - `reference` - handle stored alongside the components.
            /// - `depth` - hierarchy depth of the row.
            ///
            /// Returns `u32` - final position of the inserted row.
            fn insertRowAtDepth(
                self: *Self,
                allocator: std.mem.Allocator,
                reference: *const EntityReference,
                depth: u32,
            ) EcsError!u32 {
                const row_count: usize = self.refs.items.len;
                for (self.cols()) |*col| {
                    try col.appendUndefined(allocator, row_count);
                }
                try self.refs.append(allocator, reference.*);
                const n: u32 = @intCast(self.refs.items.len - 1);
                const idx = self.zoneInsertionIndex(depth);
                const has_zone = idx < self.depth_zones.items.len and
                    self.depth_zones.items[idx].depth == depth;
                const target: u32 = if (has_zone)
                    self.depth_zones.items[idx].offset + self.depth_zones.items[idx].len
                else if (idx == 0)
                    0
                else
                    self.depth_zones.items[idx - 1].offset + self.depth_zones.items[idx - 1].len;
                const m: usize = if (has_zone)
                    self.depth_zones.items.len - 1 - idx
                else
                    self.depth_zones.items.len - idx;
                if (m > 0) {
                    // Rotation: the new row travels from the end up to the
                    // tail of its zone; one boundary element per deeper
                    // zone rotates down in exchange. Chain positions are
                    // p0 = n and p_i = start offset of zone idx+i-1.
                    const start = if (has_zone) idx + 1 else idx;
                    // One reusable temp sized by the widest column.
                    var max_es: usize = 0;
                    for (self.colsConst()) |*col| {
                        if (col.elem_size > max_es) {
                            max_es = col.elem_size;
                        }
                    }
                    var stack_tmp: [256]u8 = undefined;
                    const heap_tmp = if (max_es > stack_tmp.len and max_es > 0)
                        try allocator.alloc(u8, max_es)
                    else
                        null;
                    defer if (heap_tmp) |b| allocator.free(b);
                    const tmp: []u8 = if (heap_tmp) |b| b else stack_tmp[0..max_es];
                    for (self.cols()) |*col| {
                        if (col.elem_size == 0) {
                            continue;
                        }
                        const es = col.elem_size;
                        const t = tmp[0..es];
                        const buf = col.bytes.ptr;
                        @memcpy(t, buf[n * es ..][0..es]);
                        @memcpy(
                            buf[n * es ..][0..es],
                            buf[self.depth_zones.items[start + m - 1].offset * es ..][0..es],
                        );
                        var k: usize = m;
                        while (k > 1) : (k -= 1) {
                            @memcpy(
                                buf[self.depth_zones.items[start + k - 1].offset * es ..][0..es],
                                buf[self.depth_zones.items[start + k - 2].offset * es ..][0..es],
                            );
                        }
                        @memcpy(buf[self.depth_zones.items[start].offset * es ..][0..es], t);
                    }
                    {
                        const refs = self.refs.items;
                        const tmp_ref = refs[n];
                        refs[n] = refs[self.depth_zones.items[start + m - 1].offset];
                        var k: usize = m;
                        while (k > 1) : (k -= 1) {
                            refs[self.depth_zones.items[start + k - 1].offset] =
                                refs[self.depth_zones.items[start + k - 2].offset];
                        }
                        refs[self.depth_zones.items[start].offset] = tmp_ref;
                    }
                    for (0..m + 1) |i| {
                        const pos: u32 = if (i == 0)
                            n
                        else
                            self.depth_zones.items[start + i - 1].offset;
                        Ecs.entity_row.items[self.refs.items[pos].id] = pos;
                    }
                } else {
                    Ecs.entity_row.items[reference.id] = n;
                }
                if (has_zone) {
                    self.depth_zones.items[idx].len += 1;
                    for (idx + 1..self.depth_zones.items.len) |z| {
                        self.depth_zones.items[z].offset += 1;
                    }
                } else {
                    try self.depth_zones.insert(allocator, idx, .{
                        .depth = depth,
                        .offset = target,
                        .len = 1,
                    });
                    for (idx + 1..self.depth_zones.items.len) |z| {
                        self.depth_zones.items[z].offset += 1;
                    }
                }
                return target;
            }
            /// Removes a row from its depth zone. The last row of the
            /// zone swaps into the removed slot (order inside the zone is
            /// irrelevant), then deeper zones shift down by one slot,
            /// costing exactly one moved row per deeper zone. Updates
            /// `entity_row` for every relocated row.
            /// - `self` - storage to mutate.
            /// - `index` - row position to remove.
            fn removeRow(self: *Self, index: u32) void {
                const zi = self.zoneIndexByOffset(index);
                const zone = self.depth_zones.items[zi];
                const e_d: u32 = zone.offset + zone.len - 1;
                const m: usize = self.depth_zones.items.len - 1 - zi;
                for (self.cols()) |*col| {
                    if (col.elem_size == 0) {
                        continue;
                    }
                    if (index == e_d) {
                        continue;
                    }
                    const es = col.elem_size;
                    @memcpy(
                        col.bytes.ptr[index * es ..][0..es],
                        col.bytes.ptr[e_d * es ..][0..es],
                    );
                }
                self.refs.items[index] = self.refs.items[e_d];
                Ecs.entity_row.items[self.refs.items[index].id] = index;
                if (m > 0) {
                    var i: usize = 1;
                    while (i <= m) : (i += 1) {
                        const dst: u32 = if (i == 1)
                            e_d
                        else
                            self.depth_zones.items[zi + i - 1].offset +
                                self.depth_zones.items[zi + i - 1].len - 1;
                        const src: u32 = self.depth_zones.items[zi + i].offset +
                            self.depth_zones.items[zi + i].len - 1;
                        for (self.cols()) |*col| {
                            if (col.elem_size == 0) {
                                continue;
                            }
                            const es = col.elem_size;
                            @memcpy(
                                col.bytes.ptr[dst * es ..][0..es],
                                col.bytes.ptr[src * es ..][0..es],
                            );
                        }
                        self.refs.items[dst] = self.refs.items[src];
                    }
                    var j: usize = 0;
                    while (j < m) : (j += 1) {
                        const pos: u32 = if (j == 0)
                            e_d
                        else
                            self.depth_zones.items[zi + j].offset +
                                self.depth_zones.items[zi + j].len - 1;
                        Ecs.entity_row.items[self.refs.items[pos].id] = pos;
                    }
                }
                const row_count: usize = self.refs.items.len;
                for (self.cols()) |*col| {
                    col.popRow(row_count);
                }
                _ = self.refs.pop();
                self.depth_zones.items[zi].len -= 1;
                for (zi + 1..self.depth_zones.items.len) |z| {
                    self.depth_zones.items[z].offset -= 1;
                }
                if (self.depth_zones.items[zi].len == 0) {
                    std.mem.copyForwards(
                        DepthZone,
                        self.depth_zones.items[zi..],
                        self.depth_zones.items[zi + 1 ..],
                    );
                    _ = self.depth_zones.pop();
                }
            }
            /// Re-sorts every row by hierarchy depth and rebuilds the
            /// depth zones in one pass. Used by bulk creation, where
            /// appending many rows through `insertRowAtDepth` would pay
            /// the per-row cascade; a single stable sort is cheaper.
            /// Updates `entity_row` for every row.
            /// - `self` - storage to mutate.
            /// - `allocator` - funds scratch and zone-list allocation.
            /// - `perm_scratch` - reusable scratch for row indices.
            /// - `visited_scratch` - reusable scratch for cycle marks.
            fn consolidateZones(
                self: *Self,
                allocator: std.mem.Allocator,
                perm_scratch: *std.ArrayListUnmanaged(u32),
                visited_scratch: *std.ArrayListUnmanaged(u8),
            ) EcsError!void {
                const n = self.refs.items.len;
                if (n == 0) {
                    self.depth_zones.clearRetainingCapacity();
                    return;
                }
                try perm_scratch.resize(allocator, n);
                for (0..n) |i| {
                    perm_scratch.items[i] = @intCast(i);
                }
                const Ctx = struct {
                    depths: []const u32,
                    refs: []const EntityReference,
                    fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                        const da = ctx.depths[ctx.refs[a].id];
                        const db = ctx.depths[ctx.refs[b].id];
                        return da < db or (da == db and a < b);
                    }
                };
                std.mem.sort(u32, perm_scratch.items, Ctx{
                    .depths = Ecs.entity_depth.items,
                    .refs = self.refs.items,
                }, Ctx.lessThan);
                try visited_scratch.resize(allocator, n);
                @memset(visited_scratch.items[0..n], 0);
                const perm = perm_scratch.items;
                const visited = visited_scratch.items;
                for (self.cols()) |*col| {
                    if (col.elem_size == 0) {
                        continue;
                    }
                    const es = col.elem_size;
                    var stack_tmp: [256]u8 = undefined;
                    const heap_tmp = if (es > stack_tmp.len)
                        try allocator.alloc(u8, es)
                    else
                        null;
                    defer if (heap_tmp) |b| allocator.free(b);
                    const tbuf: []u8 = if (heap_tmp) |b| b else stack_tmp[0..es];
                    const buf = col.bytes.ptr;
                    @memset(visited[0..n], 0);
                    for (0..n) |start| {
                        if (visited[start] != 0) {
                            continue;
                        }
                        @memcpy(tbuf, buf[start * es ..][0..es]);
                        var j: usize = start;
                        while (true) {
                            const next: usize = perm[j];
                            if (next == start) {
                                @memcpy(buf[j * es ..][0..es], tbuf);
                                break;
                            }
                            @memcpy(buf[j * es ..][0..es], buf[next * es ..][0..es]);
                            j = next;
                        }
                        var mark: usize = start;
                        while (true) {
                            visited[mark] = 1;
                            mark = perm[mark];
                            if (mark == start) {
                                break;
                            }
                        }
                    }
                }
                {
                    const refs = self.refs.items;
                    @memset(visited[0..n], 0);
                    for (0..n) |start| {
                        if (visited[start] != 0) {
                            continue;
                        }
                        const tmp = refs[start];
                        var j: usize = start;
                        while (true) {
                            const next: usize = perm[j];
                            if (next == start) {
                                refs[j] = tmp;
                                break;
                            }
                            refs[j] = refs[next];
                            j = next;
                        }
                        var mark: usize = start;
                        while (true) {
                            visited[mark] = 1;
                            mark = perm[mark];
                            if (mark == start) {
                                break;
                            }
                        }
                    }
                }
                self.depth_zones.clearRetainingCapacity();
                var i: usize = 0;
                while (i < n) {
                    const depth = Ecs.entity_depth.items[self.refs.items[i].id];
                    var j: usize = i + 1;
                    while (j < n and Ecs.entity_depth.items[self.refs.items[j].id] == depth) : (j += 1) {}
                    try self.depth_zones.append(allocator, .{
                        .depth = depth,
                        .offset = @intCast(i),
                        .len = @intCast(j - i),
                    });
                    // Rewrite entity_row for every row of the run, not
                    // just its first element.
                    for (i..j) |pos| {
                        Ecs.entity_row.items[self.refs.items[pos].id] = @intCast(pos);
                    }
                    i = j;
                }
            }
            /// Releases every column buffer, the reference list and the
            /// depth zones. Column metadata (`len`, `comp_id`, sizes) is
            /// kept so the storage stays usable without re-init.
            /// - `self` - storage to release.
            /// - `allocator` - allocator that funded the lists.
            fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                for (self.cols()) |*col| {
                    col.deinit(allocator);
                }
                self.refs.deinit(allocator);
                self.refs = .empty;
                self.depth_zones.deinit(allocator);
                self.depth_zones = .empty;
            }
        };
        /// Every archetype storage. Homogeneous array: the comptime
        /// generation only sets each entry's `len`, `arch` and column
        /// metadata; rows are added at runtime.
        var storages: [ARCH_COUNT]ArchetypeStorage = blk: {
            @setEvalBranchQuota(10_000_000);
            var tmp: [ARCH_COUNT]ArchetypeStorage = undefined;
            for (0..ARCH_COUNT) |j| {
                tmp[j] = .{ .arch = @intCast(j), .len = Tables.arch_lens[j] };
                for (0..Tables.arch_lens[j]) |k| {
                    const T: type = Tables.arch_types[j][k];
                    tmp[j].columns[k] = .{
                        .elem_size = @sizeOf(T),
                        .alignment = @alignOf(T),
                        .comp_id = Tables.arch_comp[j][k],
                    };
                }
            }
            break :blk tmp;
        };
        /// Number of 64-bit words covering all archetype occupancy bits.
        const ARCH_WORDS: usize = (ARCH_COUNT + 63) / 64;
        /// Occupancy bits, one per archetype: 1 means the storage holds at
        /// least one row, 0 means empty. Dense (`512` flags per cache line)
        /// so `nonEmptyPages()` filters without touching scattered headers.
        var archetype_nonempty_bits: [ARCH_WORDS]u64 = [_]u64{0} ** ARCH_WORDS;
        /// Checks the occupancy bit of one archetype.
        /// - `arch_id` - archetype id, an index into `archetypes`.
        ///
        /// Returns `bool` - true when the archetype holds at least one row.
        inline fn isArchetypeNonEmpty(arch_id: u32) bool {
            const word: u64 = Ecs.archetype_nonempty_bits[arch_id >> 6];
            const bit: u6 = @intCast(arch_id & 63);
            return (word >> bit) & 1 == 1;
        }
        /// Marks one archetype as non-empty.
        /// - `arch_id` - archetype id to mark.
        inline fn setArchetypeNonEmpty(arch_id: u32) void {
            const bit: u6 = @intCast(arch_id & 63);
            Ecs.archetype_nonempty_bits[arch_id >> 6] |= @as(u64, 1) << bit;
        }
        /// Marks one archetype as empty.
        /// - `arch_id` - archetype id to mark.
        inline fn clearArchetypeNonEmpty(arch_id: u32) void {
            const bit: u6 = @intCast(arch_id & 63);
            Ecs.archetype_nonempty_bits[arch_id >> 6] &= ~(@as(u64, 1) << bit);
        }
        /// Typed column access by runtime archetype id is plain O(1)
        /// indexing into the homogeneous `storages` array; no getter
        /// tables and no `inline for` dispatch chains.
        /// Entity slots in SoA form. Position `id` in every column describes
        /// one slot: `entity_generation[id]` is the live generation,
        /// `entity_archetype[id]` owns the row, `entity_row[id]` is the row.
        /// Pending lifecycle states live one packed byte per slot in
        /// `entity_states` (a `packed struct` of flags, so adding a new kind
        /// of pending command never requires repacking).
        /// A slot id always equals its position; ids are never stored.
        var entity_generation: std.ArrayListUnmanaged(u8) = .empty;
        /// Owning archetype per slot, parallel to `entity_generation`.
        var entity_archetype: std.ArrayListUnmanaged(u32) = .empty;
        /// Row inside the owning archetype storage, parallel to `entity_generation`.
        var entity_row: std.ArrayListUnmanaged(u32) = .empty;
        /// Pending state per slot, one packed byte each.
        var entity_states: std.ArrayListUnmanaged(EntityState) = .empty;
        /// Parent slot per entity, `NO_ENTITY` for roots. Parallel to
        /// `entity_generation`. Owned by the hierarchy core; users only read
        /// through `EntityReference` methods.
        var entity_parent: std.ArrayListUnmanaged(u32) = .empty;
        /// First child slot per entity, `NO_ENTITY` when childless.
        var entity_first_child: std.ArrayListUnmanaged(u32) = .empty;
        /// Last child slot per entity, `NO_ENTITY` when childless. Makes
        /// child attach O(1); maintained alongside the sibling links.
        var entity_last_child: std.ArrayListUnmanaged(u32) = .empty;
        /// Next sibling slot per entity, `NO_ENTITY` for the last child.
        var entity_next_sibling: std.ArrayListUnmanaged(u32) = .empty;
        /// Previous sibling slot per entity, `NO_ENTITY` for the first child.
        var entity_prev_sibling: std.ArrayListUnmanaged(u32) = .empty;
        /// Hierarchy depth per entity: 0 for detached entities, always
        /// `depth[parent] + 1` for children. Drives the depth zones.
        var entity_depth: std.ArrayListUnmanaged(u32) = .empty;
        /// Parent queued by a not-yet-flushed reparent command, or
        /// `NO_ENTITY` when the slot has no queued reparent. Also acts as the
        /// "reparent pending" marker: any queued command on the slot is
        /// rejected while it is set.
        var entity_pending_parent: std.ArrayListUnmanaged(u32) = .empty;
        /// Reusable scratch for depth-zone consolidation (row permutation).
        var zone_scratch_perm: std.ArrayListUnmanaged(u32) = .empty;
        /// Reusable scratch for depth-zone consolidation (visited marks).
        var zone_scratch_visited: std.ArrayListUnmanaged(u8) = .empty;
        /// Stack of freed entity ids ready for reuse.
        var free_ids: std.ArrayListUnmanaged(u32) = .empty;
        /// Counts entity slots.
        /// - Returns `usize` - number of slots ever assigned.
        fn entityStateLen() usize {
            return Ecs.entity_generation.items.len;
        }
        /// Reads the pending state of one slot. Caller must ensure `id` is in
        /// range.
        /// - `entity_index` - slot id to read.
        ///
        /// Returns `EntityState` - stored state of the slot.
        fn getEntityState(entity_index: u32) EntityState {
            return Ecs.entity_states.items[entity_index];
        }
        /// Writes the pending state of one slot. Caller must ensure `id` is in
        /// range and `entity_states` already covers it.
        /// - `entity_index` - slot id to write.
        /// - `next` - pending state to store.
        fn setEntityState(entity_index: u32, next: EntityState) void {
            Ecs.entity_states.items[entity_index] = next;
        }
        /// Grows the state store with idle (`{}`) entries to cover
        /// `slot_count` slots.
        /// - `allocator` - funds the growth.
        /// - `slot_count` - number of slots that must be addressable afterwards.
        fn ensureEntityStates(allocator: std.mem.Allocator, slot_count: usize) EcsError!void {
            const have: usize = Ecs.entity_states.items.len;
            if (slot_count > have) {
                try Ecs.entity_states.appendNTimes(allocator, .{}, slot_count - have);
            }
        }
        /// Requires the referenced slot to be alive and idle: no queued
        /// destroy/migrate/reparent and no reserved-create flag.
        /// - `ref` - entity reference to validate.
        fn requireIdle(ref: EntityReference) EcsError!u32 {
            if (!ref.isAlive()) {
                return EcsError.EntityIsNotAlive;
            }
            const entity_index: u32 = ref.id;
            if (!Ecs.getEntityState(entity_index).isIdle()) {
                return EcsError.EntityHasPendingCommand;
            }
            if (Ecs.entity_pending_parent.items[entity_index] != NO_ENTITY) {
                return EcsError.EntityHasPendingCommand;
            }
            return entity_index;
        }
        /// Validates a candidate parent for `cmdCreateChild`/`cmdCreateChildren`:
        /// either a live entity with no pending command, or a slot reserved by
        /// a queued create in this batch (so trees can be built in one pass).
        /// - `parent` - candidate parent to validate.
        fn requireParent(parent: EntityReference) EcsError!void {
            if (!parent.exists()) {
                return EcsError.EntityIsNotAlive;
            }
            const state = Ecs.getEntityState(parent.id);
            if (parent.isAlive()) {
                if (!state.isIdle()) {
                    return EcsError.EntityHasPendingCommand;
                }
                return;
            }
            if (state.pending_create) {
                return;
            }
            return EcsError.EntityIsNotAlive;
        }
        /// Clears the pending flag of a slot, ignoring never-assigned ids.
        /// Used when discarding queued commands after a failing system.
        /// - `entity_index` - slot id to release.
        fn clearPending(entity_index: u32) void {
            if (entity_index < Ecs.entityStateLen()) {
                Ecs.setEntityState(entity_index, .{});
            }
        }
        /// Reserves a slot for a queued create command: takes a recycled id
        /// (resetting its hierarchy state) or appends a fresh slot, and marks
        /// it `pending_create` so the returned reference is not alive until
        /// the command flushes. Slot arrays grow atomically: capacity is
        /// ensured up front, so a partial append can never leave a torn slot.
        /// - `allocator` - funds fresh-slot growth.
        /// - `arch` - archetype id the future entity will own.
        ///
        /// Returns `Reservation` - future handle plus recycle provenance.
        fn reserveSlot(allocator: std.mem.Allocator, arch: u32) EcsError!Reservation {
            if (Ecs.free_ids.pop()) |recycled| {
                const id = recycled;
                const gen = Ecs.entity_generation.items[id];
                Ecs.entity_archetype.items[id] = arch;
                Ecs.entity_row.items[id] = 0;
                Ecs.entity_parent.items[id] = NO_ENTITY;
                Ecs.entity_first_child.items[id] = NO_ENTITY;
                Ecs.entity_next_sibling.items[id] = NO_ENTITY;
                Ecs.entity_prev_sibling.items[id] = NO_ENTITY;
                Ecs.entity_last_child.items[id] = NO_ENTITY;
                Ecs.entity_depth.items[id] = 0;
                Ecs.entity_pending_parent.items[id] = NO_ENTITY;
                Ecs.setEntityState(id, .{ .pending_create = true });
                return .{
                    .ref = .{ .id = @intCast(id), .gen = gen },
                    .from_free = true,
                };
            }
            const next_len = Ecs.entity_generation.items.len + 1;
            try Ecs.entity_generation.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_archetype.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_row.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_states.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_parent.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_first_child.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_last_child.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_next_sibling.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_prev_sibling.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_depth.ensureTotalCapacity(allocator, next_len);
            try Ecs.entity_pending_parent.ensureTotalCapacity(allocator, next_len);
            const id: u32 = @intCast(Ecs.entity_generation.items.len);
            Ecs.entity_generation.appendAssumeCapacity(0);
            Ecs.entity_archetype.appendAssumeCapacity(arch);
            Ecs.entity_row.appendAssumeCapacity(0);
            Ecs.entity_states.appendAssumeCapacity(.{ .pending_create = true });
            Ecs.entity_parent.appendAssumeCapacity(NO_ENTITY);
            Ecs.entity_first_child.appendAssumeCapacity(NO_ENTITY);
            Ecs.entity_last_child.appendAssumeCapacity(NO_ENTITY);
            Ecs.entity_next_sibling.appendAssumeCapacity(NO_ENTITY);
            Ecs.entity_prev_sibling.appendAssumeCapacity(NO_ENTITY);
            Ecs.entity_depth.appendAssumeCapacity(0);
            Ecs.entity_pending_parent.appendAssumeCapacity(NO_ENTITY);
            return .{
                .ref = .{ .id = @intCast(id), .gen = 0 },
                .from_free = false,
            };
        }
        /// Releases a reserved slot when its create command is discarded.
        /// Recycled ids return to the free list; fresh ids pop the appended
        /// slot arrays again (callers must release in reverse reservation
        /// order so the popped id is always the last appended slot).
        /// - `allocator` - funds the free-list push.
        /// - `reservation` - slot to release.
        fn releaseReservation(allocator: std.mem.Allocator, reservation: Reservation) EcsError!void {
            if (reservation.from_free) {
                Ecs.setEntityState(reservation.ref.id, .{});
                try Ecs.free_ids.append(allocator, reservation.ref.id);
                return;
            }
            std.debug.assert(reservation.ref.id == Ecs.entity_generation.items.len - 1);
            _ = Ecs.entity_generation.pop();
            _ = Ecs.entity_archetype.pop();
            _ = Ecs.entity_row.pop();
            _ = Ecs.entity_states.pop();
            _ = Ecs.entity_parent.pop();
            _ = Ecs.entity_first_child.pop();
            _ = Ecs.entity_last_child.pop();
            _ = Ecs.entity_next_sibling.pop();
            _ = Ecs.entity_prev_sibling.pop();
            _ = Ecs.entity_depth.pop();
            _ = Ecs.entity_pending_parent.pop();
        }
        /// Initializes a reserved slot as a real entity: inserts its row into
        /// the depth zone of `depth`, records the row and clears the
        /// reservation flag. Component bytes are filled by the caller.
        /// - `allocator` - funds row allocation.
        /// - `ref` - reserved handle of the entity.
        /// - `arch` - owning archetype id.
        /// - `depth` - hierarchy depth of the new entity.
        ///
        /// Returns `u32` - row position of the created entity.
        fn initReservedSlot(
            allocator: std.mem.Allocator,
            ref: EntityReference,
            arch: u32,
            depth: u32,
        ) EcsError!u32 {
            @setEvalBranchQuota(10_000_000);
            const id: u32 = ref.id;
            Ecs.entity_depth.items[id] = depth;
            const index: u32 = blk: {
                const idx = try Ecs.storages[arch].insertRowAtDepth(allocator, &ref, depth);
                if (Ecs.storages[arch].count() == 1) {
                    Ecs.setArchetypeNonEmpty(arch);
                }
                break :blk idx;
            };
            Ecs.entity_row.items[id] = index;
            Ecs.setEntityState(id, .{});
            try EventStore(Create).fileLifecycle(allocator, arch, ref, .{});
            return index;
        }
        /// Appends rows for a batch of already-reserved slots (all at their
        /// current `entity_depth` values), clears their reservation flags and
        /// consolidates the depth zones once. Used by the `create_batch` and
        /// `create_children` commands.
        /// - `allocator` - funds row allocation and zone consolidation.
        /// - `arch` - owning archetype id.
        /// - `refs` - reserved handles, in creation order.
        ///
        /// Returns `u32` - first row index of the batch (before consolidation).
        fn initReservedBatch(
            allocator: std.mem.Allocator,
            arch: u32,
            refs: []const EntityReference,
        ) EcsError!u32 {
            @setEvalBranchQuota(10_000_000);
            const row_start: u32 = @intCast(Ecs.storages[arch].refs.items.len);
            for (refs) |ref| {
                const pos = try Ecs.storages[arch].add(allocator, &ref);
                Ecs.entity_row.items[ref.id] = pos;
                Ecs.setEntityState(ref.id, .{});
                try EventStore(Create).fileLifecycle(allocator, arch, ref, .{});
            }
            if (row_start == 0) {
                Ecs.setArchetypeNonEmpty(arch);
            }
            return row_start;
        }
        /// Attaches a brand-new entity as the last child of a live parent:
        /// sets the parent link, the depth and appends to the sibling list.
        /// O(1) via the cached tail: no sibling walk. Only used for freshly
        /// created children; reparenting of existing entities goes through
        /// `reparentById`.
        /// - `id` - child slot id.
        /// - `parent_id` - parent slot id.
        fn linkChild(id: u32, parent_id: u32) void {
            Ecs.entity_parent.items[id] = parent_id;
            Ecs.entity_prev_sibling.items[id] = Ecs.entity_last_child.items[parent_id];
            Ecs.entity_next_sibling.items[id] = NO_ENTITY;
            if (Ecs.entity_last_child.items[parent_id] == NO_ENTITY) {
                Ecs.entity_first_child.items[parent_id] = id;
            } else {
                Ecs.entity_next_sibling.items[Ecs.entity_last_child.items[parent_id]] = id;
            }
            Ecs.entity_last_child.items[parent_id] = id;
        }
        /// Resolves the effective parent of a slot: the queued reparent target
        /// when one exists, otherwise the committed parent. Lets command-time
        /// cycle checks see the hierarchy shape a batch will produce.
        /// - `entity_index` - slot id to resolve.
        ///
        /// Returns `u32` - effective parent slot, or `NO_ENTITY`.
        fn effectiveParent(entity_index: u32) u32 {
            const pending = Ecs.entity_pending_parent.items[entity_index];
            if (pending != NO_ENTITY) {
                return pending;
            }
            return Ecs.entity_parent.items[entity_index];
        }
        /// Removes an entity from its parent's child list (O(1) via the
        /// sibling links) and clears its own sibling links. The entity keeps
        /// its hierarchy data otherwise; caller decides the new parent.
        /// - `entity_index` - slot id to unlink.
        fn unlinkFromParent(entity_index: u32) void {
            const parent = Ecs.entity_parent.items[entity_index];
            if (parent == NO_ENTITY) {
                return;
            }
            const prev = Ecs.entity_prev_sibling.items[entity_index];
            const next = Ecs.entity_next_sibling.items[entity_index];
            if (prev != NO_ENTITY) {
                Ecs.entity_next_sibling.items[prev] = next;
            } else {
                Ecs.entity_first_child.items[parent] = next;
            }
            if (next != NO_ENTITY) {
                Ecs.entity_prev_sibling.items[next] = prev;
            } else {
                // Removed the last child: the tail follows.
                Ecs.entity_last_child.items[parent] = prev;
            }
            Ecs.entity_parent.items[entity_index] = NO_ENTITY;
            Ecs.entity_prev_sibling.items[entity_index] = NO_ENTITY;
            Ecs.entity_next_sibling.items[entity_index] = NO_ENTITY;
        }
        /// Destroys one already-unlinked slot: removes its row from the
        /// owning archetype (through the depth-zone cascade), resets every
        /// hierarchy field, bumps the generation and recycles the id.
        /// Callers guarantee all descendants were destroyed before this node.
        /// - `id` - slot id to destroy.
        /// - `allocator` - funds the free-slot bookkeeping.
        fn destroyNode(id: u32, allocator: std.mem.Allocator) EcsError!void {
            @setEvalBranchQuota(10_000_000);
            const arch: u32 = Ecs.entity_archetype.items[id];
            const row: u32 = Ecs.entity_row.items[id];
            const dead = EntityReference{ .id = @intCast(id), .gen = Ecs.entity_generation.items[id] };
            Ecs.storages[arch].removeRow(row);
            if (Ecs.storages[arch].count() == 0) {
                Ecs.clearArchetypeNonEmpty(arch);
            }
            Ecs.unlinkFromParent(id);
            Ecs.entity_parent.items[id] = NO_ENTITY;
            Ecs.entity_first_child.items[id] = NO_ENTITY;
            Ecs.entity_next_sibling.items[id] = NO_ENTITY;
            Ecs.entity_prev_sibling.items[id] = NO_ENTITY;
            Ecs.entity_last_child.items[id] = NO_ENTITY;
            Ecs.entity_depth.items[id] = 0;
            Ecs.entity_pending_parent.items[id] = NO_ENTITY;
            // Purge live-generation entries, then file the Destroy record
            // with the pre-bump generation: ordering keeps the record while
            // history of past instances (older generations) also survives.
            try Ecs.notifyEventEntityDestroyed(id, allocator);
            try Ecs.notifyAttributeDestroyed(id, allocator);
            try EventStore(Destroy).fileLifecycle(allocator, arch, dead, .{ .archetype = arch });
            Ecs.entity_generation.items[id] +%= 1;
            Ecs.setEntityState(id, .{});
            try Ecs.free_ids.append(allocator, id);
        }
        /// Names the storage type of one archetype id. All archetypes share
        /// the homogeneous `ArchetypeStorage` type.
        /// - `id` - archetype id. Must be comptime-known.
        ///
        /// Returns `type` - storage type of the archetype.
        /// Private: direct storage access can reallocate; use `SystemHandler`.
        fn Storage(comptime id: usize) type {
            _ = id;
            return ArchetypeStorage;
        }
        /// Returns a direct pointer to the storage of the given component bundle.
        /// Plain array indexing, no dispatch.
        /// Private: direct storage access can reallocate; use `SystemHandler`.
        /// - `types` - component bundle. Must exactly match a declared archetype.
        ///
        /// Returns `*Storage` - live storage of the archetype.
        fn storage(comptime types: anytype) *ArchetypeStorage {
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
            @setEvalBranchQuota(10_000_000);
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
                try Ecs.ensureEntityStates(allocator, Ecs.entity_generation.items.len);
                try Ecs.entity_parent.append(allocator, NO_ENTITY);
                try Ecs.entity_first_child.append(allocator, NO_ENTITY);
                try Ecs.entity_last_child.append(allocator, NO_ENTITY);
                try Ecs.entity_next_sibling.append(allocator, NO_ENTITY);
                try Ecs.entity_prev_sibling.append(allocator, NO_ENTITY);
                try Ecs.entity_depth.append(allocator, 0);
                try Ecs.entity_pending_parent.append(allocator, NO_ENTITY);
                new_gen = 0;
            }
            const reference = EntityReference{
                .id = @intCast(new_id),
                .gen = new_gen,
            };
            // Every entity is born as a root (depth 0) and lands in the
            // depth-0 zone of its archetype. Recycled slots get every
            // hierarchy field reset, so a reused id never inherits links.
            const index: u32 = blk: {
                const idx = try Ecs.storages[id].insertRowAtDepth(allocator, &reference, 0);
                if (Ecs.storages[id].count() == 1) {
                    Ecs.setArchetypeNonEmpty(id);
                }
                break :blk idx;
            };
            Ecs.entity_generation.items[new_id] = new_gen;
            Ecs.entity_archetype.items[new_id] = id;
            Ecs.entity_row.items[new_id] = index;
            Ecs.entity_parent.items[new_id] = NO_ENTITY;
            Ecs.entity_first_child.items[new_id] = NO_ENTITY;
            Ecs.entity_last_child.items[new_id] = NO_ENTITY;
            Ecs.entity_next_sibling.items[new_id] = NO_ENTITY;
            Ecs.entity_prev_sibling.items[new_id] = NO_ENTITY;
            Ecs.entity_depth.items[new_id] = 0;
            Ecs.entity_pending_parent.items[new_id] = NO_ENTITY;
            Ecs.setEntityState(new_id, .{});
            try EventStore(Create).fileLifecycle(allocator, id, reference, .{});
            return reference;
        }
        /// Creates `count` entities at once, all roots (depth 0). Slots are
        /// allocated first, then rows are appended raw and depth zones are
        /// rebuilt in one consolidation pass, so bulk creation costs one
        /// stable sort instead of one zone cascade per row.
        /// Private: used by the `create_batch` command.
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
            return Ecs.storages[id].count();
        }
        /// Returns a pointer to one component value at a row. The pointer is
        /// mutable: component data lives in global storage, no handle state
        /// is modified by the lookup. One binary search over the sorted
        /// component ids plus direct column indexing, no dispatch chain.
        /// Undeclared and absent types both report
        /// `ComponentNotFoundInArchetype`, exactly as before.
        /// - `arch_id` - archetype id owning the row.
        /// - `T` - component type to look up.
        /// - `index` - row position.
        ///
        /// Returns `*T` - pointer into the component column.
        /// Private: use `SystemHandler.getComponent`.
        fn getComponent(
            arch_id: u32,
            comptime T: type,
            index: u32,
        ) EcsError!*T {
            if (comptime componentIndex(T) == null) {
                return EcsError.ComponentNotFoundInArchetype;
            }
            const comp_id: u32 = @intCast(comptime componentIndex(T).?);
            const col = Ecs.binarySearchIds(
                Ecs.archetypes[arch_id].component_ids,
                comp_id,
            ) orelse return EcsError.ComponentNotFoundInArchetype;
            const s = &Ecs.storages[arch_id];
            const n: usize = s.refs.items.len;
            if (index >= n) {
                return EcsError.IndexOutOfBounds;
            }
            if (@sizeOf(T) == 0) {
                return @ptrCast(@alignCast(@constCast(s.columns[col].bytes.ptr)));
            }
            const column = &s.columns[col];
            std.debug.assert(column.elem_size == @sizeOf(T));
            const typed: [*]T = @ptrCast(@alignCast(column.bytes.ptr));
            return &typed[index];
        }
        /// Copies values of components shared by two archetype rows.
        /// Pure runtime byte copies driven by the sorted component id
        /// lists; no unrolling over archetypes or component types.
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
            const dst = &Ecs.storages[dst_id];
            const src_ids = Ecs.archetypes[src_id].component_ids;
            const src = &Ecs.storages[src_id];
            for (dst.cols()) |*dcol| {
                if (dcol.elem_size == 0) {
                    continue;
                }
                const scol_idx = Ecs.binarySearchIds(src_ids, dcol.comp_id) orelse continue;
                const scol = &src.columns[scol_idx];
                const es = dcol.elem_size;
                @memcpy(
                    dcol.bytes.ptr[dst_index * es ..][0..es],
                    scol.bytes.ptr[src_index * es ..][0..es],
                );
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
        /// Sorts a type buffer by `(name hash, name)`, in place. Hashes are
        /// hoisted once (`O(n)`), the quadratic selection pass then touches
        /// only integers; the name tie-break keeps a total order so id
        /// mapping stays order-preserving (ascending `arch_comp` rows,
        /// ascending `qids`). Replaces the old per-site bubble sorts;
        /// `std.mem.sort` is not comptime-safe here.
        /// - `N` - buffer capacity. Must be comptime-known.
        /// - `buf` - buffer holding the types. Evaluated in comptime.
        /// - `len` - number of valid entries at the start of `buf`.
        fn sortTypesByName(comptime N: usize, comptime buf: *[N]type, len: usize) void {
            var keys: [N]u64 = undefined;
            for (0..len) |i| {
                keys[i] = hashTypeName(buf[i]);
            }
            var i: usize = 0;
            while (i < len) : (i += 1) {
                var m: usize = i;
                var j: usize = i + 1;
                while (j < len) : (j += 1) {
                    if (keys[j] < keys[m] or
                        (keys[j] == keys[m] and typeNameLess(buf[j], buf[m])))
                    {
                        m = j;
                    }
                }
                if (m != i) {
                    const tt: type = buf[i];
                    buf[i] = buf[m];
                    buf[m] = tt;
                    const tk: u64 = keys[i];
                    keys[i] = keys[m];
                    keys[m] = tk;
                }
            }
        }
        /// Orders two types by fully qualified name (tie-break for equal
        /// name hashes in `sortTypesByName`).
        /// - `a` - left type.
        /// - `b` - right type.
        ///
        /// Returns `bool` - true when `a` sorts before `b`.
        fn typeNameLess(comptime a: type, comptime b: type) bool {
            return std.mem.order(u8, @typeName(a), @typeName(b)) == .lt;
        }
        /// Hashes a type name for ordering. Collisions only cost a rare
        /// name tie-break; order stays total via `typeKeyLess`.
        /// - `T` - type whose name to hash.
        ///
        /// Returns `u64` - FNV-1a hash of the fully qualified name.
        fn hashTypeName(comptime T: type) u64 {
            var h: u64 = 0xcbf29ce484222325;
            for (@typeName(T)) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            return h;
        }
        /// Hashes a canonical (sorted, unique) type list. Used to bucket
        /// archetypes before exact dedup comparison.
        /// - `types` - canonical type list to hash.
        ///
        /// Returns `u64` - FNV-1a hash over member type names and length.
        fn hashTypeSet(comptime types: []const type) u64 {
            var h: u64 = 0xcbf29ce484222325;
            h ^= @as(u64, types.len);
            h *%= 0x100000001b3;
            for (types) |T| {
                for (@typeName(T)) |b| {
                    h ^= b;
                    h *%= 0x100000001b3;
                }
                h ^= 0xff;
                h *%= 0x100000001b3;
            }
            return h;
        }
        /// Sort key pairing an archetype hash with its input index.
        const HashIndex = struct {
            hash: u64,
            index: usize,
        };
        /// Orders hash buckets for archetype dedup.
        fn hashIndexLessThan(_: void, a: HashIndex, b: HashIndex) bool {
            return a.hash < b.hash;
        }
        /// Sorts hash buckets by hash, in place. Bottom-up iterative
        /// mergesort, `O(n log n)` integer compares only: the dedup index
        /// sort must not go quadratic when archetypes number in thousands.
        /// No aliasing hazards at comptime (plain data, no `type` values).
        /// - `order` - buckets to sort. Evaluated in comptime.
        /// - `scratch` - temporary buffer, at least `order.len` entries.
        fn sortHashIndices(order: []HashIndex, scratch: []HashIndex) void {
            var width: usize = 1;
            while (width < order.len) : (width *= 2) {
                var lo: usize = 0;
                while (lo < order.len) : (lo += 2 * width) {
                    const mid: usize = @min(lo + width, order.len);
                    const hi: usize = @min(lo + 2 * width, order.len);
                    var a: usize = lo;
                    var b: usize = mid;
                    var c: usize = lo;
                    while (a < mid and b < hi) {
                        if (order[b].hash < order[a].hash) {
                            scratch[c] = order[b];
                            b += 1;
                        } else {
                            scratch[c] = order[a];
                            a += 1;
                        }
                        c += 1;
                    }
                    while (a < mid) : (a += 1) {
                        scratch[c] = order[a];
                        c += 1;
                    }
                    while (b < hi) : (b += 1) {
                        scratch[c] = order[b];
                        c += 1;
                    }
                    for (scratch[lo..hi], lo..) |v, idx| {
                        order[idx] = v;
                    }
                }
            }
        }
        /// Binary-searches a `(hash, name)`-sorted component type list, the
        /// order produced by `sortTypesByName`.
        /// - `T` - component type to look up.
        /// - `comps` - sorted component types.
        ///
        /// Returns `?usize` - position inside the list, or null when absent.
        fn componentIndexInSorted(comptime T: type, comptime comps: []const type) ?usize {
            const needle_hash: u64 = hashTypeName(T);
            const needle: []const u8 = @typeName(T);
            var low: usize = 0;
            var high: usize = comps.len;
            while (low < high) {
                const mid: usize = low + (high - low) / 2;
                const mid_hash: u64 = hashTypeName(comps[mid]);
                if (mid_hash < needle_hash) {
                    low = mid + 1;
                    continue;
                }
                if (mid_hash > needle_hash) {
                    high = mid;
                    continue;
                }
                switch (std.mem.order(u8, @typeName(comps[mid]), needle)) {
                    .lt => low = mid + 1,
                    .gt => high = mid,
                    .eq => return mid,
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
                /// Precomputed canonical column index per query component:
                /// `cols[qi]` is the position in `storages[arch_id].columns`
                /// of `query[qi]`. Filled once in comptime by
                /// `PagesContainer`, so `get` needs no binary search.
                cols: [query.len]u32 = [_]u32{0} ** query.len,
                /// Returns the whole mutable column of one component via the
                /// precomputed map: comptime query position plus one runtime
                /// array load, no search and no indirect call.
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
                    const qi = comptime indexOfType(query, T);
                    const s = &Ecs.storages[self.arch_id];
                    const n = s.refs.items.len;
                    if (n == 0) {
                        return &[0]T{};
                    }
                    if (@sizeOf(T) == 0) {
                        const base: [*]T = @ptrCast(@alignCast(@constCast(s.columns[self.cols[qi]].bytes.ptr)));
                        return base[0..n];
                    }
                    const col = &s.columns[self.cols[qi]];
                    std.debug.assert(col.elem_size == @sizeOf(T));
                    const typed: [*]T = @ptrCast(@alignCast(col.bytes.ptr));
                    return typed[0..n];
                }
                /// Returns the entity reference column, read-only, by direct
                /// indexing into the homogeneous storage array.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const EntityReference` - read-only reference list.
                pub fn entities(self: *const PageNamespace) []const EntityReference {
                    return Ecs.storages[self.arch_id].refs.items;
                }
                /// Returns an immutable reference to the source archetype info.
                /// - `self` - page to inspect.
                ///
                /// Returns `*const ArchetypeInfo` - source archetype descriptor.
                pub fn archetypeInfo(self: *const PageNamespace) *const ArchetypeInfo {
                    return &Ecs.archetypes[self.arch_id];
                }
                /// Checks whether the page holds no entities, via the global
                /// occupancy bit. Touches only the dense bitset, not storage.
                /// - `self` - page to inspect.
                ///
                /// Returns `bool` - true when the archetype storage is empty.
                pub inline fn isEmpty(self: *const PageNamespace) bool {
                    return !Ecs.isArchetypeNonEmpty(self.arch_id);
                }
                /// Read-only view of one depth zone: a contiguous run of rows
                /// sharing one hierarchy depth. Obtained from
                /// `Page.zone(depth)` or `Page.zoneAt(index)`; the underlying
                /// column slice is a sub-slice of the full column.
                pub const ZoneView = struct {
                    /// Owning page (archetype handle) of the zone.
                    page: PageNamespace,
                    /// The zone descriptor: depth plus row range.
                    zone: DepthZone,
                    /// Number of rows in the zone.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `u32` - zone row count.
                    pub fn len(self: *const ZoneView) u32 {
                        return self.zone.len;
                    }
                    /// Returns the zone's depth.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `u32` - hierarchy depth of the zone.
                    pub fn depth(self: *const ZoneView) u32 {
                        return self.zone.depth;
                    }
                    /// Returns the zone's component column slice.
                    /// - `self` - zone view to inspect.
                    /// - `T` - component type, must be part of the query.
                    ///
                    /// Returns `[]T` - mutable slice over the zone rows.
                    pub fn get(self: *const ZoneView, comptime T: type) []T {
                        comptime {
                            if (!hasType(query, T)) {
                                @compileError("Requested component type is not part of this page.");
                            }
                        }
                        const qi = comptime indexOfType(query, T);
                        const s = &Ecs.storages[self.page.arch_id];
                        if (self.zone.len == 0) {
                            return &[0]T{};
                        }
                        if (@sizeOf(T) == 0) {
                            const base: [*]T = @ptrCast(@alignCast(@constCast(s.columns[self.page.cols[qi]].bytes.ptr)));
                            return base[self.zone.offset..][0..self.zone.len];
                        }
                        const col = &s.columns[self.page.cols[qi]];
                        std.debug.assert(col.elem_size == @sizeOf(T));
                        const typed: [*]T = @ptrCast(@alignCast(col.bytes.ptr));
                        return typed[self.zone.offset..][0..self.zone.len];
                    }
                    /// Returns the zone's entity reference slice.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `[]const EntityReference` - zone row references.
                    pub fn entities(self: *const ZoneView) []const EntityReference {
                        return Ecs.storages[self.page.arch_id].refs.items[self.zone.offset..][0..self.zone.len];
                    }
                };
                /// Returns every depth zone of the page, sorted ascending by
                /// depth. Zones are always valid: structural operations
                /// maintain them eagerly, so no rebuild is triggered here.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const DepthZone` - zone list of the archetype.
                pub fn depthZones(self: *const PageNamespace) []const DepthZone {
                    return Ecs.storages[self.arch_id].depth_zones.items;
                }
                /// Returns the zone of one depth, or null when the page holds
                /// no entity at that depth.
                /// - `self` - page to inspect.
                /// - `depth` - hierarchy depth to look up.
                ///
                /// Returns `?DepthZone` - zone descriptor, or null.
                pub fn depthZone(self: *const PageNamespace, depth: u32) ?DepthZone {
                    const zones = Ecs.storages[self.arch_id].depth_zones.items;
                    var lo: usize = 0;
                    var hi: usize = zones.len;
                    while (lo < hi) {
                        const mid = (lo + hi) / 2;
                        if (zones[mid].depth < depth) {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                    if (lo < zones.len and zones[lo].depth == depth) {
                        return zones[lo];
                    }
                    return null;
                }
                /// Number of distinct depths currently present in the page.
                /// - `self` - page to inspect.
                ///
                /// Returns `usize` - depth zone count.
                pub fn depthCount(self: *const PageNamespace) usize {
                    return Ecs.storages[self.arch_id].depth_zones.items.len;
                }
                /// Deepest depth present in the page, or null when empty.
                /// - `self` - page to inspect.
                ///
                /// Returns `?u32` - deepest depth, or null.
                pub fn maxDepth(self: *const PageNamespace) ?u32 {
                    const zones = Ecs.storages[self.arch_id].depth_zones.items;
                    if (zones.len == 0) {
                        return null;
                    }
                    return zones[zones.len - 1].depth;
                }
                /// Returns a zone view for one depth. A missing depth yields
                /// an empty view with the same depth, so callers can iterate
                /// unconditionally.
                /// - `self` - page to inspect.
                /// - `depth` - hierarchy depth.
                ///
                /// Returns `ZoneView` - view over the zone rows.
                pub fn zone(self: *const PageNamespace, depth: u32) ZoneView {
                    const z = self.depthZone(depth) orelse return ZoneView{
                        .page = self.*,
                        .zone = .{ .depth = depth, .offset = 0, .len = 0 },
                    };
                    return ZoneView{
                        .page = self.*,
                        .zone = z,
                    };
                }
                /// Returns a zone view for one row position, resolved through
                /// the zone offsets. Useful to iterate zones sequentially.
                /// - `self` - page to inspect.
                /// - `index` - zone list index (`0 <= index < depthCount()`).
                ///
                /// Returns `ZoneView` - view over the indexed zone rows.
                pub fn zoneAt(self: *const PageNamespace, index: usize) ZoneView {
                    const z = Ecs.storages[self.arch_id].depth_zones.items[index];
                    return ZoneView{
                        .page = self.*,
                        .zone = z,
                    };
                }
            };
        }
        /// Container of pages for archetypes containing all `include`
        /// components and none of the `exclude` components.
        /// The match list is precomputed in comptime; no allocator is needed.
        /// `allPages()` returns the immutable array of every matched page.
        /// `nonEmptyPages()` filters that array through the dense global
        /// `archetype_nonempty_bits` into a per-query static buffer and
        /// returns its filled prefix. The slice is valid until the next
        /// `nonEmptyPages()` call for the same query, so consume it in a
        /// single expression: `for (h.pages(...).nonEmptyPages()) |p|`.
        /// - `include` - component bundle that must be present.
        /// - `exclude` - component bundle that must be absent. `null` and empty
        ///   bundles are equivalent to no exclusion.
        ///
        /// Returns `type` - container over the matched archetype ids.
        /// Private: containers are only issued by `SystemHandler`.
        fn PagesContainer(comptime include: anytype, comptime exclude: anytype) type {
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
                @setEvalBranchQuota(10_000_000);
                // Rarest-seed scan: iterate only archetypes of the least
                // frequent include component, verify the rest by merge.
                // Seed lists are ascending, so the result stays ordered.
                // include is never empty (canonicalQuery rejects it).
                var seed: u32 = qids[0];
                var seed_len: usize = comp_arch_lens[seed];
                for (qids[1..]) |qid| {
                    const l: usize = comp_arch_lens[qid];
                    if (l < seed_len) {
                        seed = qid;
                        seed_len = l;
                    }
                }
                const seed_list = comp_arch_flat[comp_arch_off[seed]..][0..seed_len];
                var list: [ARCH_COUNT]u32 = undefined;
                var total: usize = 0;
                for (seed_list) |a| {
                    const ids = Tables.arch_comp[a][0..Tables.arch_lens[a]];
                    var qi: usize = 0;
                    var ii: usize = 0;
                    var ok: bool = true;
                    while (qi < qids.len) {
                        while (ii < ids.len and ids[ii] < qids[qi]) : (ii += 1) {}
                        if (ii >= ids.len or ids[ii] != qids[qi]) {
                            ok = false;
                            break;
                        }
                        qi += 1;
                        ii += 1;
                    }
                    if (!ok) {
                        continue;
                    }
                    var di: usize = 0;
                    ii = 0;
                    while (di < deny_ids.len and ii < ids.len) {
                        if (ids[ii] < deny_ids[di]) {
                            ii += 1;
                        } else if (ids[ii] > deny_ids[di]) {
                            di += 1;
                        } else {
                            ok = false;
                            break;
                        }
                    }
                    if (!ok) {
                        continue;
                    }
                    list[total] = a;
                    total += 1;
                }
                break :blk .{ .list = list, .len = total };
            };
            return struct {
                /// Per-query static scratch for the filtered prefix. One
                /// buffer per distinct query type, shared by all calls, so
                /// the returned slice stays alive after the temporary
                /// container dies. Overwritten by the next `nonEmptyPages()`
                /// call for the same query.
                var nonempty_buf: [matched.len]Page(include) = undefined;
                /// Immutable array of every matched page, precomputed once.
                /// Each entry carries its archetype id plus the precomputed
                /// query-to-column map, so `Page.get` needs no search.
                const all_pages: [matched.len]Page(include) = blk: {
                    @setEvalBranchQuota(10_000_000);
                    var arr: [matched.len]Page(include) = undefined;
                    for (0..matched.len) |i| {
                        const a = matched.list[i];
                        var cols: [query.len]u32 = undefined;
                        for (qids, 0..) |qid, qi| {
                            const ids = Tables.arch_comp[a][0..Tables.arch_lens[a]];
                            var found: u32 = 0;
                            for (ids, 0..) |cid, ci| {
                                if (cid == qid) {
                                    found = @intCast(ci);
                                    break;
                                }
                            }
                            cols[qi] = found;
                        }
                        arr[i] = .{ .arch_id = a, .cols = cols };
                    }
                    break :blk arr;
                };
                /// Returns every matched page, including empty ones.
                /// - `self` - container to inspect. Taken by value so the
                ///   call works on a temporary: `h.pages(...).allPages()`.
                ///
                /// Returns `[]const Page(include)` - static slice, always valid.
                pub fn allPages(self: @This()) []const Page(include) {
                    _ = self;
                    return &all_pages;
                }
                /// Returns only pages holding at least one entity. Filters via
                /// the dense bitset, without touching storage headers.
                /// - `self` - container to inspect. Taken by value so the
                ///   call works on a temporary: `h.pages(...).nonEmptyPages()`.
                ///
                /// Returns `[]Page(include)` - static-buffer slice, valid until
                /// the next `nonEmptyPages()` call for the same query.
                pub fn nonEmptyPages(self: @This()) []Page(include) {
                    _ = self;
                    var total: usize = 0;
                    for (all_pages) |p| {
                        if (!p.isEmpty()) {
                            @This().nonempty_buf[total] = p;
                            total += 1;
                        }
                    }
                    return @This().nonempty_buf[0..total];
                }
            };
        }
        /// Shared target check for every set path of events and attributes:
        /// the slot must exist and be alive or reserved by `cmdCreate` in
        /// the same system; destroy-pending slots are rejected. Single
        /// straight-line check without re-reading generation: exactly the
        /// `exists` + `isAlive` + pending semantics, fused.
        /// - `ref` - entity reference to validate.
        fn validateSetTarget(ref: EntityReference) EcsError!void {
            const id: u32 = ref.id;
            if (id >= Ecs.entity_generation.items.len) {
                return EcsError.EntityIsNotAlive;
            }
            const state = Ecs.getEntityState(id);
            if (Ecs.entity_generation.items[id] != ref.gen) {
                return EcsError.EntityIsNotAlive;
            }
            if (!state.pending_create and state.pending_destroy) {
                return EcsError.EntityHasPendingCommand;
            }
        }
        /// Validates an event payload type. Events are plain structs living
        /// outside the archetype/component registry: any struct works, it
        /// never has to be declared in `ECS(...)`. Zero-size structs are
        /// valid marker events.
        /// - `E` - event payload type. Must be a struct, never `EntityReference`.
        fn validateEventType(comptime E: type) void {
            if (@typeInfo(E) != .@"struct") {
                @compileError("Event type must be a struct type.");
            }
            if (E == EntityReference) {
                @compileError("EntityReference cannot be an event type.");
            }
        }
        /// Opaque handle of one registered event. Issued only by
        /// `EventPage.handleAt`, never built by hand: `cmdDestroyEvent`
        /// validates the handle against committed events, so forged handles
        /// fail with `EventNotFound`. Lookup is by entity id plus generation;
        /// `arch_id` and `index` are placement hints only. A handle stays
        /// usable within the frame while its entity is neither migrated nor
        /// destroyed: both operations invalidate the stored generation.
        /// - `E` - event payload type the handle refers to.
        ///
        /// Returns `type` - handle type bound to the payload.
        pub fn EventHandle(comptime E: type) type {
            validateEventType(E);
            return struct {
                /// Payload tag. Lets `cmdDestroyEvent` infer `E` from the
                /// handle type and reject handles of foreign payloads.
                pub const EventPayload = E;
                /// Entity the event is attached to, with the generation
                /// observed when the handle was issued.
                entity: EntityReference,
                /// Archetype page holding the event when the handle was
                /// issued. Placement hint only.
                arch_id: u32,
                /// Row inside that page when the handle was issued.
                /// Placement hint only.
                index: u32,
            };
        }
        /// Lifecycle event filed automatically for every created entity, once
        /// per creation, visible to later systems until the frame end. Empty:
        /// the entity comes from the page itself.
        pub const Create = struct {};
        /// Lifecycle event filed automatically for every destroyed entity.
        /// The archetype is captured because a dead reference resolves nothing.
        pub const Destroy = struct {
            /// Archetype the entity belonged to when destroyed.
            archetype: u32,
        };
        /// Lifecycle event filed automatically for every entity migrate.
        /// Repeat migrates in one frame append (full history).
        pub const Migrate = struct {
            /// Archetype the entity leaves.
            from: u32,
            /// Archetype the entity enters.
            to: u32,
        };
        /// Lifecycle event filed automatically when an entity parent changes
        /// (same-parent reorderings excluded). Depth changes ride in a
        /// separate `DepthUpdate` record, so one entity may carry both.
        pub const Reparent = struct {
            /// Previous parent, or null when the entity was a root.
            old_parent: ?EntityReference,
            /// New parent, or null when detached into a root.
            new_parent: ?EntityReference,
        };
        /// Lifecycle event filed automatically for every entity whose
        /// hierarchy depth changes: reparented roots and moved subtree
        /// members alike.
        pub const DepthUpdate = struct {
            /// Depth before the change.
            old_depth: u32,
            /// Depth after the change.
            new_depth: u32,
        };
        /// Optional per-payload buffer budgets. Unset (`null`) fields grow
        /// forever, exactly like today. Set fields pre-grow on assignment
        /// (warmup) and trim back down at every frame end; mid-frame growth
        /// past any budget is always allowed (correctness first).
        pub const EventLimits = struct {
            /// Entity slot coverage of the slot maps. Warmup only in effect:
            /// trimming never drops live coverage, only spare capacity.
            slots: ?u32 = null,
            /// Pending queue capacity. Warmed on assignment, trimmed post-clear.
            pending: ?u32 = null,
            /// Page column capacity, pooled shells included. Warmed on
            /// assignment (shell count comes from `pages`), trimmed post-clear.
            events_per_page: ?u32 = null,
            /// Committed outer capacity plus pooled shell count. Warmed on
            /// assignment, trimmed post-clear.
            pages: ?u32 = null,
        };
        /// Dense page of events of one payload type over one archetype:
        /// `entities[i]` carries `values[i]`. Pages of one payload are sorted
        /// ascending by `arch_id` and only non-empty pages are stored.
        /// Read-only by contract: mutate only through `cmdSetEvent` /
        /// `cmdDestroyEvent`, and treat the view as valid only until the
        /// current system returns. Rows are appended in emission order, but
        /// destroys swap the last row into the removed slot, so positions
        /// are unstable: address events by handle, never by index, across
        /// systems.
        /// - `E` - event payload type stored in the page.
        ///
        /// Returns `type` - page type holding one archetype id.
        pub fn EventPage(comptime E: type) type {
            validateEventType(E);
            return struct {
                const Self = @This();
                /// Archetype the page events were filed under: the live
                /// archetype of every listed entity.
                arch_id: u32,
                /// Entities carrying the event, parallel to `values`.
                entities: std.ArrayListUnmanaged(EntityReference) = .empty,
                /// Event payloads, parallel to `entities`.
                values: std.ArrayListUnmanaged(E) = .empty,
                /// Chain links for the per-slot rows, packed like the store
                /// `rows` map (high 32 bits: archetype id, low 32: row).
                /// `NO_PACK` terminates. Private by contract.
                next: std.ArrayListUnmanaged(u64) = .empty,
                /// Counts events on the page.
                /// - `self` - page to inspect.
                ///
                /// Returns `usize` - number of stored events.
                pub fn count(self: *const Self) usize {
                    return self.entities.items.len;
                }
                /// Checks whether the page holds no events.
                /// - `self` - page to inspect.
                ///
                /// Returns `bool` - true when the page is empty.
                pub fn isEmpty(self: *const Self) bool {
                    return self.entities.items.len == 0;
                }
                /// Fetches the entity carrying the event at the given position.
                /// - `self` - page to inspect.
                /// - `index` - event position.
                ///
                /// Returns `EntityReference` - handle stored in the row.
                pub fn entityAt(self: *const Self, index: usize) EntityReference {
                    return self.entities.items[index];
                }
                /// Fetches the payload stored at the given position.
                /// - `self` - page to inspect.
                /// - `index` - event position.
                ///
                /// Returns `*const E` - pointer into the payload column.
                pub fn valueAt(self: *const Self, index: usize) *const E {
                    return &self.values.items[index];
                }
                /// Issues the destroy handle of the event at the given
                /// position. The only legal source of `cmdDestroyEvent` input.
                /// - `self` - page to inspect.
                /// - `index` - event position.
                ///
                /// Returns `EventHandle(E)` - handle of the event.
                pub fn handleAt(self: *const Self, index: usize) EventHandle(E) {
                    return .{
                        .entity = self.entities.items[index],
                        .arch_id = self.arch_id,
                        .index = @intCast(index),
                    };
                }
                /// Exposes the entity column, read-only.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const EntityReference` - entities carrying events.
                pub fn entityList(self: *const Self) []const EntityReference {
                    return self.entities.items;
                }
                /// Exposes the payload column, read-only.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const E` - stored payloads.
                pub fn eventList(self: *const Self) []const E {
                    return self.values.items;
                }
                /// Returns an immutable reference to the source archetype info.
                /// - `self` - page to inspect.
                ///
                /// Returns `*const ArchetypeInfo` - source archetype descriptor.
                pub fn archetypeInfo(self: *const Self) *const ArchetypeInfo {
                    return &Ecs.archetypes[self.arch_id];
                }
            };
        }
        /// Opaque handle of one stored attribute. Issued only by
        /// `AttributePage.handleAt`, never built by hand: `cmdDestroyAttribute`
        /// validates the handle against committed attributes, so forged
        /// handles fail with `AttributeNotFound`. Lookup is by entity id
        /// plus generation; `arch_id` and `index` are placement hints only.
        /// A handle stays usable while its entity is neither migrated nor
        /// destroyed: both operations invalidate the stored generation.
        /// - `E` - attribute payload type the handle refers to.
        ///
        /// Returns `type` - handle type bound to the payload.
        pub fn AttributeHandle(comptime E: type) type {
            validateEventType(E);
            return struct {
                /// Payload tag. Lets `cmdDestroyAttribute` infer `E` from the
                /// handle type and reject handles of foreign payloads.
                pub const AttributePayload = E;
                /// Entity carrying the attribute, with the generation
                /// observed when the handle was issued.
                entity: EntityReference,
                /// Archetype page holding the attribute when the handle was
                /// issued. Placement hint only.
                arch_id: u32,
                /// Row inside that page when the handle was issued.
                /// Placement hint only.
                index: u32,
            };
        }
        /// Dense page of attributes of one payload type over one archetype:
        /// `entities[i]` carries `values[i]`. Pages of one payload are sorted
        /// ascending by `arch_id` and only non-empty pages are stored. Rows
        /// are grouped into depth zones exactly like component storages, so
        /// hierarchy depth can be iterated without touching entity columns.
        /// Read-only by contract, except through `getAttribute` and zone
        /// views which expose mutable values like component columns do.
        /// Treat any view as valid only until the current system returns.
        /// - `E` - attribute payload type stored in the page.
        ///
        /// Returns `type` - page type holding one archetype id.
        pub fn AttributePage(comptime E: type) type {
            validateEventType(E);
            return struct {
                const Self = @This();
                /// Archetype the page attributes were filed under: the live
                /// archetype of every listed entity.
                arch_id: u32,
                /// Entities carrying the attribute, parallel to `values`.
                entities: std.ArrayListUnmanaged(EntityReference) = .empty,
                /// Attribute payloads, parallel to `entities`.
                values: std.ArrayListUnmanaged(E) = .empty,
                /// Contiguous depth zones tiling the row array, maintained
                /// exactly like component storage zones.
                depth_zones: std.ArrayListUnmanaged(DepthZone) = .empty,
                /// Counts attributes on the page.
                /// - `self` - page to inspect.
                ///
                /// Returns `usize` - number of stored attributes.
                pub fn count(self: *const Self) usize {
                    return self.entities.items.len;
                }
                /// Checks whether the page holds no attributes.
                /// - `self` - page to inspect.
                ///
                /// Returns `bool` - true when the page is empty.
                pub fn isEmpty(self: *const Self) bool {
                    return self.entities.items.len == 0;
                }
                /// Fetches the entity carrying the attribute at the given position.
                /// - `self` - page to inspect.
                /// - `index` - attribute position.
                ///
                /// Returns `EntityReference` - handle stored in the row.
                pub fn entityAt(self: *const Self, index: usize) EntityReference {
                    return self.entities.items[index];
                }
                /// Fetches the payload stored at the given position.
                /// - `self` - page to inspect.
                /// - `index` - attribute position.
                ///
                /// Returns `*const E` - pointer into the payload column.
                pub fn valueAt(self: *const Self, index: usize) *const E {
                    return &self.values.items[index];
                }
                /// Issues the destroy handle of the attribute at the given
                /// position. The only legal source of `cmdDestroyAttribute`
                /// input.
                /// - `self` - page to inspect.
                /// - `index` - attribute position.
                ///
                /// Returns `AttributeHandle(E)` - handle of the attribute.
                pub fn handleAt(self: *const Self, index: usize) AttributeHandle(E) {
                    return .{
                        .entity = self.entities.items[index],
                        .arch_id = self.arch_id,
                        .index = @intCast(index),
                    };
                }
                /// Exposes the entity column, read-only.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const EntityReference` - entities carrying attributes.
                pub fn entityList(self: *const Self) []const EntityReference {
                    return self.entities.items;
                }
                /// Exposes the payload column, read-only.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const E` - stored payloads.
                pub fn attributeList(self: *const Self) []const E {
                    return self.values.items;
                }
                /// Returns an immutable reference to the source archetype info.
                /// - `self` - page to inspect.
                ///
                /// Returns `*const ArchetypeInfo` - source archetype descriptor.
                pub fn archetypeInfo(self: *const Self) *const ArchetypeInfo {
                    return &Ecs.archetypes[self.arch_id];
                }
                /// Read-only view of one depth zone: a contiguous run of rows
                /// sharing one hierarchy depth. Obtained from
                /// `AttributePage.zone(depth)` or `AttributePage.zoneAt(index)`.
                pub const ZoneView = struct {
                    /// Owning page (archetype handle) of the zone.
                    page: Self,
                    /// The zone descriptor: depth plus row range.
                    zone: DepthZone,
                    /// Number of rows in the zone.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `u32` - zone row count.
                    pub fn len(self: *const ZoneView) u32 {
                        return self.zone.len;
                    }
                    /// Returns the zone's depth.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `u32` - hierarchy depth of the zone.
                    pub fn depth(self: *const ZoneView) u32 {
                        return self.zone.depth;
                    }
                    /// Returns the zone's payload slice, mutable like
                    /// component columns: attributes are mid-term state that
                    /// systems read and write in place.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `[]E` - mutable slice over the zone rows.
                    pub fn values(self: *const ZoneView) []E {
                        return self.page.values.items[self.zone.offset..][0..self.zone.len];
                    }
                    /// Returns the zone's entity reference slice.
                    /// - `self` - zone view to inspect.
                    ///
                    /// Returns `[]const EntityReference` - zone row references.
                    pub fn entities(self: *const ZoneView) []const EntityReference {
                        return self.page.entities.items[self.zone.offset..][0..self.zone.len];
                    }
                };
                /// Returns every depth zone of the page, sorted ascending by
                /// depth.
                /// - `self` - page to inspect.
                ///
                /// Returns `[]const DepthZone` - zone list of the page.
                pub fn depthZones(self: *const Self) []const DepthZone {
                    return self.depth_zones.items;
                }
                /// Returns the zone of one depth, or null when the page holds
                /// no attribute at that depth.
                /// - `self` - page to inspect.
                /// - `depth` - hierarchy depth to look up.
                ///
                /// Returns `?DepthZone` - zone descriptor, or null.
                pub fn depthZone(self: *const Self, depth: u32) ?DepthZone {
                    const zones = self.depth_zones.items;
                    var lo: usize = 0;
                    var hi: usize = zones.len;
                    while (lo < hi) {
                        const mid = (lo + hi) / 2;
                        if (zones[mid].depth < depth) {
                            lo = mid + 1;
                        } else {
                            hi = mid;
                        }
                    }
                    if (lo < zones.len and zones[lo].depth == depth) {
                        return zones[lo];
                    }
                    return null;
                }
                /// Number of distinct depths currently present in the page.
                /// - `self` - page to inspect.
                ///
                /// Returns `usize` - depth zone count.
                pub fn depthCount(self: *const Self) usize {
                    return self.depth_zones.items.len;
                }
                /// Deepest depth present in the page, or null when empty.
                /// - `self` - page to inspect.
                ///
                /// Returns `?u32` - deepest depth, or null.
                pub fn maxDepth(self: *const Self) ?u32 {
                    const zones = self.depth_zones.items;
                    if (zones.len == 0) {
                        return null;
                    }
                    return zones[zones.len - 1].depth;
                }
                /// Returns a zone view for one depth. A missing depth yields
                /// an empty view with the same depth, so callers can iterate
                /// unconditionally.
                /// - `self` - page to inspect.
                /// - `depth` - hierarchy depth.
                ///
                /// Returns `ZoneView` - view over the zone rows.
                pub fn zone(self: *const Self, depth: u32) ZoneView {
                    const z = self.depthZone(depth) orelse return ZoneView{
                        .page = self.*,
                        .zone = .{ .depth = depth, .offset = 0, .len = 0 },
                    };
                    return ZoneView{
                        .page = self.*,
                        .zone = z,
                    };
                }
                /// Returns a zone view for one row position, resolved through
                /// the zone offsets. Useful to iterate zones sequentially.
                /// - `self` - page to inspect.
                /// - `index` - zone list index (`0 <= index < depthCount()`).
                ///
                /// Returns `ZoneView` - view over the indexed zone rows.
                pub fn zoneAt(self: *const Self, index: usize) ZoneView {
                    const z = self.depth_zones.items[index];
                    return ZoneView{
                        .page = self.*,
                        .zone = z,
                    };
                }
            };
        }
        /// Committed pages plus the pending queue of one event payload type.
        /// One instantiation per payload: `committed` is the sparse sorted
        /// page list read by `allEvents`/`filterEvents`, `pending` holds the
        /// collapsed net commands of the running system (at most one op per
        /// entity, rewritten in place by repeated `cmdSetEvent`).
        /// - `E` - event payload type.
        ///
        /// Returns `type` - store namespace with per-payload static state.
        /// Private: stores are only reached through `SystemHandler` and the
        /// flush/discard/clear plumbing.
        fn EventStore(comptime E: type) type {
            return struct {
                const Store = @This();
                /// One pending command of the running system.
                const Pending = struct {
                    entity: EntityReference,
                    op: union(enum) {
                        set: E,
                        destroy: void,
                    },
                };
                /// Committed pages, sorted ascending by `arch_id`, non-empty only.
                var committed: std.ArrayListUnmanaged(EventPage(E)) = .empty;
                /// Collapsed net commands of the running system.
                var pending: std.ArrayListUnmanaged(Pending) = .empty;
                /// Empty page shells with retained buffers, reused across
                /// frames so steady-state event flow allocates nothing.
                var page_pool: std.ArrayListUnmanaged(EventPage(E)) = .empty;
                /// Entity slot id to the head of its committed chain, packed
                /// as `(arch_id << 32) | row`; `NO_PACK` means no entry.
                /// Every lookup is array loads, no hashing.
                var rows: std.ArrayListUnmanaged(u64) = .empty;
                /// Entity slot id to position in `pending`, or `NO_PENDING`.
                /// Rewrites happen in place; indices stay valid because
                /// pending entries are only appended or cleared wholesale.
                var pending_rows: std.ArrayListUnmanaged(u32) = .empty;
                /// Bulk-wipe armed by `queueDestroyAll`: the flush drops every
                /// committed page instead of removing rows one by one. Reset
                /// by every flush and every discard, so it never leaks across.
                var wiped: bool = false;
                /// Pending length at bulk time: ops below it die with the
                /// wipe, ops at and above it (queued after) apply normally.
                var wipe_mark: usize = 0;
                /// Whether committed holds anything worth clearing.
                var dirty: bool = false;
                /// Optional budgets (see `EventLimits`): replace-semantics via
                /// `setEventLimits`, cleared by `clearEventLimits`. Read only
                /// in the setter and at frame-end clear; never on hot paths.
                var limits: EventLimits = .{};
                /// Empty chain link / empty slot value.
                const NO_PACK: u64 = std.math.maxInt(u64);
                /// Empty pending slot value.
                const NO_PENDING: u32 = std.math.maxInt(u32);
                /// Whether the payload registered its type-erased callbacks.
                var registered: bool = false;
                /// Lazily appends the payload callbacks to the event registry
                /// on first queued command. Read-only payloads never register.
                /// - `allocator` - funds the registry append.
                fn ensureRegistered(allocator: std.mem.Allocator) EcsError!void {
                    if (registered) {
                        return;
                    }
                    try Ecs.event_registry.append(allocator, .{
                        .name = @typeName(E),
                        .flush = flushPending,
                        .discardPending = discardPending,
                        .clearCommitted = clearCommitted,
                        .deinitStore = deinitStore,
                        .onEntityDestroyed = onEntityDestroyed,
                        .onEntityMigrated = onEntityMigrated,
                        .resetRegistered = resetRegistered,
                    });
                    registered = true;
                }
                /// Marks the payload as unregistered, so a reused ECS after
                /// `deinit` registers it again on next use.
                fn resetRegistered() void {
                    registered = false;
                }
                /// Locates the committed page of one archetype.
                /// - `arch` - archetype id to look up.
                ///
                /// Returns `?usize` - position in `committed`, or null.
                fn findPageIndex(arch: u32) ?usize {
                    var low: usize = 0;
                    var high: usize = committed.items.len;
                    while (low < high) {
                        const mid: usize = low + (high - low) / 2;
                        const a: u32 = committed.items[mid].arch_id;
                        if (a < arch) {
                            low = mid + 1;
                        } else if (a > arch) {
                            high = mid;
                        } else {
                            return mid;
                        }
                    }
                    return null;
                }
                /// Finds the sorted insertion point of an archetype id.
                /// - `arch` - archetype id to insert.
                ///
                /// Returns `usize` - first page with `arch_id >= arch`.
                fn pageInsertIndex(arch: u32) usize {
                    var low: usize = 0;
                    var high: usize = committed.items.len;
                    while (low < high) {
                        const mid: usize = low + (high - low) / 2;
                        if (committed.items[mid].arch_id < arch) {
                            low = mid + 1;
                        } else {
                            high = mid;
                        }
                    }
                    return low;
                }
                /// Position of one committed event.
                const Location = struct {
                    page: usize,
                    index: usize,
                };
                /// Packs an archetype id plus a row into one chain link.
                /// - `arch` - archetype id (high 32 bits).
                /// - `row` - row position (low 32 bits).
                ///
                /// Returns `u64` - packed link.
                fn packRow(arch: u32, row: u32) u64 {
                    return (@as(u64, arch) << 32) | @as(u64, row);
                }
                /// Resolves a packed link to a live location. Page indices
                /// shift on page insert/drop, but packs store the immutable
                /// archetype id, so resolution re-searches by archetype and
                /// stays exact; bounds-checked against row moves. Bursts
                /// usually hit a single page: that case skips the binary
                /// search with two loads.
                /// - `link` - packed `(arch_id, row)` link.
                ///
                /// Returns `?Location` - live page and row, or null.
                fn resolvePacked(link: u64) ?Location {
                    const arch: u32 = @intCast(link >> 32);
                    const row: u32 = @intCast(link & 0xFFFF_FFFF);
                    if (committed.items.len == 1 and committed.items[0].arch_id == arch) {
                        if (row >= committed.items[0].entities.items.len) {
                            return null;
                        }
                        return .{ .page = 0, .index = row };
                    }
                    const pi = findPageIndex(arch) orelse return null;
                    if (row >= committed.items[pi].entities.items.len) {
                        return null;
                    }
                    return .{ .page = pi, .index = row };
                }
                /// Grows the slot maps to cover one slot id, filling with
                /// empty sentinels. Each side grows independently, so a
                /// partial failure can never desynchronize them.
                /// - `allocator` - funds the growth.
                /// - `slot` - entity slot id that must be addressable.
                fn ensureSlot(allocator: std.mem.Allocator, slot: u32) EcsError!void {
                    const need: usize = @as(usize, slot) + 1;
                    if (need > rows.items.len) {
                        try rows.appendNTimes(allocator, NO_PACK, need - rows.items.len);
                    }
                    if (need > pending_rows.items.len) {
                        try pending_rows.appendNTimes(allocator, NO_PENDING, need - pending_rows.items.len);
                    }
                }
                /// Repoints one chain link: the head when it matches, else
                /// the predecessor found by walking the chain.
                /// - `slot` - entity slot id owning the chain.
                /// - `from_packed` - link value to replace.
                /// - `to_packed` - replacement link value.
                fn repointSlot(slot: u32, from_packed: u64, to_packed: u64) void {
                    if (slot >= rows.items.len) {
                        return;
                    }
                    if (rows.items[slot] == from_packed) {
                        rows.items[slot] = to_packed;
                        return;
                    }
                    var cur = rows.items[slot];
                    while (cur != NO_PACK) {
                        const loc = resolvePacked(cur) orelse return;
                        if (committed.items[loc.page].next.items[loc.index] == from_packed) {
                            committed.items[loc.page].next.items[loc.index] = to_packed;
                            return;
                        }
                        cur = committed.items[loc.page].next.items[loc.index];
                    }
                }
                /// Locates the oldest committed row of one slot id plus
                /// generation by walking its chain.
                /// - `id` - entity slot id.
                /// - `gen` - entity generation.
                ///
                /// Returns `?Location` - page and row, or null when absent.
                fn findSlotRow(id: u32, gen: u8) ?Location {
                    if (id >= rows.items.len) {
                        return null;
                    }
                    var cur = rows.items[id];
                    while (cur != NO_PACK) {
                        const loc = resolvePacked(cur) orelse return null;
                        const e = committed.items[loc.page].entities.items[loc.index];
                        if (e.id == id and e.gen == gen) {
                            return loc;
                        }
                        cur = committed.items[loc.page].next.items[loc.index];
                    }
                    return null;
                }
                /// Locates a committed event by entity reference.
                /// - `ref` - entity reference to look up.
                ///
                /// Returns `?Location` - page and row, or null when absent.
                fn findByEntity(ref: EntityReference) ?Location {
                    return findSlotRow(ref.id, ref.gen);
                }
                /// Removes the row at the given position with swap-remove:
                /// the last row travels into the gap and every chain link
                /// addressing either row is repaired, so removal stays O(1)
                /// plus chain walks. Emptied pages go to the pool with
                /// buffers retained.
                /// - `allocator` - funds the pool push of a dropped page.
                /// - `pi` - position of the page in `committed`.
                /// - `k` - row position inside the page.
                fn removeAt(allocator: std.mem.Allocator, pi: usize, k: usize) EcsError!void {
                    const page = &committed.items[pi];
                    const arch = page.arch_id;
                    const gone_id: u32 = page.entities.items[k].id;
                    const gone_next: u64 = page.next.items[k];
                    const last: usize = page.entities.items.len - 1;
                    repointSlot(gone_id, packRow(arch, @intCast(k)), gone_next);
                    if (k != last) {
                        const moved_id: u32 = page.entities.items[last].id;
                        page.entities.items[k] = page.entities.items[last];
                        page.values.items[k] = page.values.items[last];
                        page.next.items[k] = page.next.items[last];
                        repointSlot(moved_id, packRow(arch, @intCast(last)), packRow(arch, @intCast(k)));
                    }
                    _ = page.entities.pop();
                    _ = page.values.pop();
                    _ = page.next.pop();
                    dirty = true;
                    if (page.entities.items.len == 0) {
                        const shell = committed.orderedRemove(pi);
                        try page_pool.append(allocator, shell);
                    }
                }
                /// Returns the page index for one archetype, reusing a pooled
                /// shell when the page is new.
                /// - `allocator` - funds the page slot.
                /// - `arch` - archetype id to look up.
                ///
                /// Returns `usize` - position in `committed`.
                fn pageIndexFor(allocator: std.mem.Allocator, arch: u32) EcsError!usize {
                    if (findPageIndex(arch)) |pi| {
                        return pi;
                    }
                    const pos = pageInsertIndex(arch);
                    if (page_pool.pop()) |shell| {
                        try committed.insert(allocator, pos, shell);
                        committed.items[pos].arch_id = arch;
                    } else {
                        try committed.insert(allocator, pos, .{ .arch_id = arch });
                    }
                    return pos;
                }
                /// Appends one committed entry in O(1) amortized, always as a
                /// new row: unlike `upsertBySlot` it never collapses an
                /// existing row, so lifecycle actions accumulate full history.
                /// The row is push-fronted onto its slot chain. Growth is
                /// atomic (capacities first, then infallible appends).
                /// - `allocator` - funds page and row allocation.
                /// - `arch` - archetype page to file under.
                /// - `ref` - entity carrying the event.
                /// - `value` - payload to store.
                fn appendRow(
                    allocator: std.mem.Allocator,
                    arch: u32,
                    ref: EntityReference,
                    value: E,
                ) EcsError!void {
                    try ensureSlot(allocator, ref.id);
                    const pi = try pageIndexFor(allocator, arch);
                    const page = &committed.items[pi];
                    const at: u32 = @intCast(page.entities.items.len);
                    try page.entities.ensureTotalCapacity(allocator, page.entities.items.len + 1);
                    try page.values.ensureTotalCapacity(allocator, page.values.items.len + 1);
                    try page.next.ensureTotalCapacity(allocator, page.next.items.len + 1);
                    page.entities.appendAssumeCapacity(ref);
                    page.values.appendAssumeCapacity(value);
                    page.next.appendAssumeCapacity(rows.items[ref.id]);
                    rows.items[ref.id] = packRow(arch, at);
                    dirty = true;
                }
                /// Files one lifecycle event directly into committed pages,
                /// bypassing the pending queue: lifecycle actions run inside
                /// the entity flush, after the event flush already passed, so
                /// queueing would defer them past the frame-end clear.
                /// Registers the payload on first use (for frame-end clear
                /// and deinit). Repeat actions append history, never collapse.
                /// - `allocator` - funds page and row allocation.
                /// - `arch` - archetype page to file under (live archetype).
                /// - `ref` - entity carrying the event.
                /// - `value` - payload to store.
                fn fileLifecycle(
                    allocator: std.mem.Allocator,
                    arch: u32,
                    ref: EntityReference,
                    value: E,
                ) EcsError!void {
                    try Store.ensureRegistered(allocator);
                    try appendRow(allocator, arch, ref, value);
                }
                /// Inserts or rewrites one committed entry in O(1) amortized:
                /// the slot chain is walked for a same-generation row and
                /// updated in place, otherwise the row appends to the arch
                /// page. No hashing anywhere on this path.
                /// - `allocator` - funds page and row allocation.
                /// - `arch` - archetype page to file under.
                /// - `ref` - entity carrying the event.
                /// - `value` - payload to store.
                fn upsertBySlot(
                    allocator: std.mem.Allocator,
                    arch: u32,
                    ref: EntityReference,
                    value: E,
                ) EcsError!void {
                    try ensureSlot(allocator, ref.id);
                    var cur = rows.items[ref.id];
                    while (cur != NO_PACK) {
                        const loc = resolvePacked(cur) orelse break;
                        const e = committed.items[loc.page].entities.items[loc.index];
                        if (e.id == ref.id and e.gen == ref.gen) {
                            committed.items[loc.page].entities.items[loc.index] = ref;
                            committed.items[loc.page].values.items[loc.index] = value;
                            dirty = true;
                            return;
                        }
                        cur = committed.items[loc.page].next.items[loc.index];
                    }
                    try appendRow(allocator, arch, ref, value);
                }
                /// Removes every committed entry of an entity reference
                /// (all history rows sharing its id plus generation),
                /// dropping pages that become empty. Silent when absent.
                /// Handles of one `(entity, generation)` pair are aliases:
                /// destroying one destroys them all.
                /// - `allocator` - funds moved-row index updates and frees
                ///   emptied pages.
                /// - `ref` - entity reference to remove.
                fn removeCommitted(allocator: std.mem.Allocator, ref: EntityReference) EcsError!void {
                    while (findByEntity(ref)) |loc| {
                        try removeAt(allocator, loc.page, loc.index);
                    }
                }
                /// Queues a set command in O(1) amortized, rewriting a pending
                /// op for the same slot in place: a pending destroy becomes a
                /// set (the destroy is cancelled and the payload updated).
                /// The append is atomic: queue capacity is ensured first, so
                /// a failed index grow cannot leave an unindexed entry behind.
                /// - `allocator` - funds the queue append.
                /// - `ref` - entity carrying the event.
                /// - `value` - payload to store.
                fn queueSet(allocator: std.mem.Allocator, ref: EntityReference, value: E) EcsError!void {
                    try ensureSlot(allocator, ref.id);
                    const slot = pending_rows.items[ref.id];
                    if (slot != NO_PENDING) {
                        pending.items[slot].entity = ref;
                        pending.items[slot].op = .{ .set = value };
                        return;
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + 1);
                    pending_rows.items[ref.id] = @intCast(pending.items.len);
                    pending.appendAssumeCapacity(.{ .entity = ref, .op = .{ .set = value } });
                }
                /// Queues a destroy command for a validated handle in O(1)
                /// amortized. A pending set for the same slot becomes a
                /// destroy (the set is cancelled); a pending destroy is a
                /// double destroy.
                /// - `allocator` - funds the queue append.
                /// - `handle` - handle issued by `EventPage.handleAt`.
                fn queueDestroy(allocator: std.mem.Allocator, handle: EventHandle(E)) EcsError!void {
                    if (findByEntity(handle.entity) == null) {
                        return EcsError.EventNotFound;
                    }
                    try ensureSlot(allocator, handle.entity.id);
                    const slot = pending_rows.items[handle.entity.id];
                    if (slot != NO_PENDING) {
                        if (pending.items[slot].op == .destroy) {
                            return EcsError.EventHasPendingCommand;
                        }
                        pending.items[slot].op = .{ .destroy = {} };
                        return;
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + 1);
                    pending_rows.items[handle.entity.id] = @intCast(pending.items.len);
                    pending.appendAssumeCapacity(.{ .entity = handle.entity, .op = .{ .destroy = {} } });
                }
                /// Queues one payload for a whole slice of entities in O(n):
                /// every target is validated first, so a bad reference fails
                /// the batch before anything is queued. Capacity for the whole
                /// batch is reserved up front, then the loop itself cannot fail.
                /// - `allocator` - funds the queued ops.
                /// - `entities` - entities carrying the event.
                /// - `value` - payload stored with every event.
                fn queueSetMany(
                    allocator: std.mem.Allocator,
                    entities: []const EntityReference,
                    value: E,
                ) EcsError!void {
                    for (entities) |ref| {
                        try Ecs.validateSetTarget(ref);
                    }
                    for (entities) |ref| {
                        try ensureSlot(allocator, ref.id);
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + entities.len);
                    for (entities) |ref| {
                        const slot = pending_rows.items[ref.id];
                        if (slot != NO_PENDING) {
                            pending.items[slot].entity = ref;
                            pending.items[slot].op = .{ .set = value };
                        } else {
                            pending_rows.items[ref.id] = @intCast(pending.items.len);
                            pending.appendAssumeCapacity(.{ .entity = ref, .op = .{ .set = value } });
                        }
                    }
                }
                /// Queues one payload per entity, pairwise, in O(n). Same
                /// validate-first, reserve-up-front discipline as `queueSetMany`.
                /// - `allocator` - funds the queued ops.
                /// - `entities` - entities carrying the events.
                /// - `values` - payload per entity, same length as `entities`.
                fn queueSetEach(
                    allocator: std.mem.Allocator,
                    entities: []const EntityReference,
                    values: []const E,
                ) EcsError!void {
                    if (entities.len != values.len) {
                        return EcsError.CountMismatch;
                    }
                    for (entities) |ref| {
                        try Ecs.validateSetTarget(ref);
                    }
                    for (entities) |ref| {
                        try ensureSlot(allocator, ref.id);
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + entities.len);
                    for (entities, values) |ref, value| {
                        const slot = pending_rows.items[ref.id];
                        if (slot != NO_PENDING) {
                            pending.items[slot].entity = ref;
                            pending.items[slot].op = .{ .set = value };
                        } else {
                            pending_rows.items[ref.id] = @intCast(pending.items.len);
                            pending.appendAssumeCapacity(.{ .entity = ref, .op = .{ .set = value } });
                        }
                    }
                }
                /// Queues destroys for a slice of entities in O(n): every
                /// entry is validated first (present, not destroy-pending),
                /// so a bad entry fails the batch before anything is queued.
                /// A duplicated entity inside one call collapses silently;
                /// a repeated call reports `EventHasPendingCommand`, mirroring
                /// the double-destroy rule.
                /// - `allocator` - funds the queued ops.
                /// - `entities` - entity references holding the events. Only
                ///   id plus generation are used; handles are not required.
                fn queueDestroyMany(
                    allocator: std.mem.Allocator,
                    entities: []const EntityReference,
                ) EcsError!void {
                    for (entities) |e| {
                        if (findByEntity(e) == null) {
                            return EcsError.EventNotFound;
                        }
                        try ensureSlot(allocator, e.id);
                        const slot = pending_rows.items[e.id];
                        if (slot != NO_PENDING and pending.items[slot].op == .destroy) {
                            return EcsError.EventHasPendingCommand;
                        }
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + entities.len);
                    for (entities) |e| {
                        const slot = pending_rows.items[e.id];
                        if (slot != NO_PENDING) {
                            // Pre-existing destroys errored above; a destroy
                            // met here was queued by this very call: skip it.
                            if (pending.items[slot].op == .destroy) {
                                continue;
                            }
                            pending.items[slot].op = .{ .destroy = {} };
                        } else {
                            pending_rows.items[e.id] = @intCast(pending.items.len);
                            pending.appendAssumeCapacity(.{ .entity = e, .op = .{ .destroy = {} } });
                        }
                    }
                }
                /// Arms a bulk wipe: O(1), no queue traffic. The flush drops
                /// every committed page to the pool instead of removing rows
                /// one by one; only ops queued after this call survive it.
                /// Idempotent within one system.
                fn queueDestroyAll() void {
                    wipe_mark = pending.items.len;
                    wiped = true;
                }
                /// Moves the pending queue into committed pages, resolving
                /// every set under the entity live archetype. Stale sets
                /// (dead or recycled slots) and stale destroys are skipped
                /// silently, mirroring entity flush semantics. The pending
                /// slot map resets inline, so no second pass is needed.
                /// - `allocator` - funds page and row allocation.
                fn flushPending(allocator: std.mem.Allocator) EcsError!void {
                    defer {
                        pending.clearRetainingCapacity();
                        wiped = false;
                    }
                    var start: usize = 0;
                    if (wiped) {
                        // Bulk wipe: drop every page to the pool and reset
                        // the slot map wholesale; ops below the mark die
                        // with it, ops at and above it apply normally.
                        for (rows.items) |*r| {
                            r.* = NO_PACK;
                        }
                        try page_pool.ensureTotalCapacity(allocator, page_pool.items.len + committed.items.len);
                        for (committed.items) |*page| {
                            page.entities.items.len = 0;
                            page.values.items.len = 0;
                            page.next.items.len = 0;
                            page_pool.appendAssumeCapacity(page.*);
                        }
                        committed.clearRetainingCapacity();
                        for (pending.items[0..wipe_mark]) |op| {
                            pending_rows.items[op.entity.id] = NO_PENDING;
                        }
                        start = wipe_mark;
                        dirty = false;
                    }
                    for (pending.items[start..]) |op| {
                        pending_rows.items[op.entity.id] = NO_PENDING;
                        switch (op.op) {
                            .set => |v| {
                                const id: u32 = op.entity.id;
                                if (id >= Ecs.entity_generation.items.len) {
                                    continue;
                                }
                                if (Ecs.entity_generation.items[id] != op.entity.gen) {
                                    continue;
                                }
                                const st = Ecs.getEntityState(id);
                                if (!op.entity.isAlive() and !st.pending_create) {
                                    continue;
                                }
                                const arch: u32 = Ecs.entity_archetype.items[id];
                                try upsertBySlot(allocator, arch, op.entity, v);
                            },
                            .destroy => {
                                try removeCommitted(allocator, op.entity);
                            },
                        }
                    }
                }
                /// Drops the pending queue without applying it. Also disarms
                /// a bulk wipe queued by the failing system.
                fn discardPending() void {
                    for (pending.items) |op| {
                        pending_rows.items[op.entity.id] = NO_PENDING;
                    }
                    pending.clearRetainingCapacity();
                    wiped = false;
                    wipe_mark = 0;
                }
                /// Clears committed pages for the frame boundary without
                /// freeing: slot maps reset by memset, page shells (buffers
                /// retained) return to the pool, the outer list keeps
                /// capacity. Steady-state frames allocate nothing here.
                /// Assigned budgets (`setEventLimits`) trim back what exceeds
                /// twice their target, so trimming stays idempotent across
                /// frames despite geometric rounding.
                /// - `allocator` - funds the pool reservation (once).
                fn clearCommitted(allocator: std.mem.Allocator) EcsError!void {
                    if (!dirty) {
                        return;
                    }
                    for (rows.items) |*r| {
                        r.* = NO_PACK;
                    }
                    try page_pool.ensureTotalCapacity(allocator, page_pool.items.len + committed.items.len);
                    for (committed.items) |*page| {
                        page.entities.items.len = 0;
                        page.values.items.len = 0;
                        page.next.items.len = 0;
                        page_pool.appendAssumeCapacity(page.*);
                    }
                    committed.clearRetainingCapacity();
                    if (limits.pages) |pg| {
                        const max_shells: usize = pg;
                        while (page_pool.items.len > max_shells) {
                            var shell = page_pool.pop().?;
                            shell.entities.deinit(allocator);
                            shell.values.deinit(allocator);
                            shell.next.deinit(allocator);
                        }
                        if (committed.capacity > 2 * max_shells) {
                            committed.deinit(allocator);
                            committed = .empty;
                            try committed.ensureTotalCapacity(allocator, max_shells);
                        }
                    }
                    if (limits.events_per_page) |ec| {
                        const cap: usize = ec;
                        for (page_pool.items) |*shell| {
                            if (shell.entities.capacity > 2 * cap) {
                                shell.entities.deinit(allocator);
                                shell.entities = .empty;
                                try shell.entities.ensureTotalCapacity(allocator, cap);
                            }
                            if (shell.values.capacity > 2 * cap) {
                                shell.values.deinit(allocator);
                                shell.values = .empty;
                                try shell.values.ensureTotalCapacity(allocator, cap);
                            }
                            if (shell.next.capacity > 2 * cap) {
                                shell.next.deinit(allocator);
                                shell.next = .empty;
                                try shell.next.ensureTotalCapacity(allocator, cap);
                            }
                        }
                    }
                    if (limits.pending) |pcap| {
                        const cap: usize = pcap;
                        if (pending.capacity > 2 * cap) {
                            pending.deinit(allocator);
                            pending = .empty;
                            try pending.ensureTotalCapacity(allocator, cap);
                        }
                    }
                    if (limits.slots) |sc| {
                        // Live length is the floor: slot coverage must never
                        // drop, only spare capacity above it is reclaimed.
                        const floor: usize = @max(rows.items.len, sc);
                        if (rows.capacity > 2 * floor) {
                            const keep = rows.items.len;
                            rows.deinit(allocator);
                            rows = .empty;
                            try rows.appendNTimes(allocator, NO_PACK, keep);
                        }
                        const pfloor: usize = @max(pending_rows.items.len, sc);
                        if (pending_rows.capacity > 2 * pfloor) {
                            const keep = pending_rows.items.len;
                            pending_rows.deinit(allocator);
                            pending_rows = .empty;
                            try pending_rows.appendNTimes(allocator, NO_PENDING, keep);
                        }
                    }
                    dirty = false;
                }
                /// Frees committed pages, pooled shells, queues and slot maps.
                /// - `allocator` - allocator that funded the store.
                fn deinitStore(allocator: std.mem.Allocator) void {
                    for (committed.items) |*page| {
                        page.entities.deinit(allocator);
                        page.values.deinit(allocator);
                        page.next.deinit(allocator);
                    }
                    committed.deinit(allocator);
                    committed = .empty;
                    for (page_pool.items) |*page| {
                        page.entities.deinit(allocator);
                        page.values.deinit(allocator);
                        page.next.deinit(allocator);
                    }
                    page_pool.deinit(allocator);
                    page_pool = .empty;
                    pending.deinit(allocator);
                    pending = .empty;
                    rows.deinit(allocator);
                    rows = .empty;
                    pending_rows.deinit(allocator);
                    pending_rows = .empty;
                    dirty = false;
                }
                /// Purges every live-generation row of one destroyed slot by
                /// walking its chain: O(chain), no page scans. History rows
                /// of past slot instances (older generations) survive, so
                /// destroy-create-destroy keeps every `Destroy` record.
                /// - `id` - destroyed entity slot id.
                /// - `allocator` - funds the pool push of a dropped page.
                fn onEntityDestroyed(id: u32, allocator: std.mem.Allocator) EcsError!void {
                    if (id >= rows.items.len) {
                        return;
                    }
                    const live: u8 = Ecs.entity_generation.items[id];
                    while (findSlotRow(id, live)) |loc| {
                        try removeAt(allocator, loc.page, loc.index);
                    }
                }
                /// Relocates one entity rows to the destination archetype
                /// page and refreshes their generation, keeping the invariant
                /// that a page arch always equals the live entity archetype.
                /// Only live-generation rows move: history rows of past
                /// instances keep their generation and stay put.
                /// - `id` - migrated entity slot id.
                /// - `old_arch` - archetype id the entity leaves.
                /// - `new_arch` - archetype id the entity enters.
                /// - `new_gen` - generation after the migrate.
                /// - `allocator` - funds the destination page slot.
                fn onEntityMigrated(
                    id: u32,
                    old_arch: u32,
                    new_arch: u32,
                    new_gen: u8,
                    allocator: std.mem.Allocator,
                ) EcsError!void {
                    if (id >= rows.items.len) {
                        return;
                    }
                    const fresh = EntityReference{ .id = @intCast(id), .gen = new_gen };
                    const old_gen: u8 = new_gen -% 1;
                    if (old_arch == new_arch) {
                        var cur = rows.items[id];
                        while (cur != NO_PACK) {
                            const loc = resolvePacked(cur) orelse break;
                            const e = committed.items[loc.page].entities.items[loc.index];
                            const nxt = committed.items[loc.page].next.items[loc.index];
                            if (e.id == id and e.gen == old_gen) {
                                committed.items[loc.page].entities.items[loc.index] = fresh;
                            }
                            cur = nxt;
                        }
                        return;
                    }
                    // Move every live-generation row, oldest first. Each step
                    // re-resolves because removals and inserts shift packs.
                    while (findSlotRowGen(id, old_gen)) |loc| {
                        const v = committed.items[loc.page].values.items[loc.index];
                        try removeAt(allocator, loc.page, loc.index);
                        try appendRow(allocator, new_arch, fresh, v);
                    }
                }
                /// Locates the oldest committed row of one slot id plus
                /// generation by walking its chain.
                /// - `id` - entity slot id.
                /// - `gen` - entity generation.
                ///
                /// Returns `?Location` - page and row, or null when absent.
                fn findSlotRowGen(id: u32, gen: u8) ?Location {
                    if (id >= rows.items.len) {
                        return null;
                    }
                    var cur = rows.items[id];
                    while (cur != NO_PACK) {
                        const loc = resolvePacked(cur) orelse return null;
                        const e = committed.items[loc.page].entities.items[loc.index];
                        if (e.id == id and e.gen == gen) {
                            return loc;
                        }
                        cur = committed.items[loc.page].next.items[loc.index];
                    }
                    return null;
                }
            };
        }
        /// Committed pages plus the pending queue of one attribute payload
        /// type. Mirrors `EventStore`, plus depth zones per page and minus
        /// frame-end clearing: attributes persist until destroyed or the ECS
        /// deinitializes. Upsert semantics keep one row per slot, so no
        /// history chains are needed: the slot map always points at the row.
        /// - `E` - attribute payload type.
        ///
        /// Returns `type` - store namespace with per-payload static state.
        /// Private: stores are only reached through `SystemHandler` and the
        /// flush/discard/trim plumbing.
        fn AttributeStore(comptime E: type) type {
            return struct {
                const Store = @This();
                /// One pending command of the running system.
                const Pending = struct {
                    entity: EntityReference,
                    op: union(enum) {
                        set: E,
                        destroy: void,
                    },
                };
                /// Position of one committed attribute.
                const Location = struct {
                    page: usize,
                    index: usize,
                };
                /// Committed pages, sorted ascending by `arch_id`, non-empty only.
                var committed: std.ArrayListUnmanaged(AttributePage(E)) = .empty;
                /// Collapsed net commands of the running system.
                var pending: std.ArrayListUnmanaged(Pending) = .empty;
                /// Empty page shells with retained buffers, reused across frames.
                var page_pool: std.ArrayListUnmanaged(AttributePage(E)) = .empty;
                /// Entity slot id to its committed row, packed as
                /// `(arch_id << 32) | row`; `NO_PACK` means no attribute.
                /// Single pack per slot: upsert keeps one row per slot.
                var rows: std.ArrayListUnmanaged(u64) = .empty;
                /// Entity slot id to position in `pending`, or `NO_PENDING`.
                var pending_rows: std.ArrayListUnmanaged(u32) = .empty;
                /// Optional budgets, same shape as events (see `EventLimits`).
                var limits: EventLimits = .{};
                /// Bulk-wipe armed by `queueDestroyAll`: the flush drops every
                /// committed page instead of removing rows one by one. Reset
                /// by every flush and every discard, so it never leaks across.
                var wiped: bool = false;
                /// Pending length at bulk time: ops below it die with the
                /// wipe, ops at and above it (queued after) apply normally.
                var wipe_mark: usize = 0;
                /// Whether the payload registered its type-erased callbacks.
                var registered: bool = false;
                /// Empty slot link value.
                const NO_PACK: u64 = std.math.maxInt(u64);
                /// Empty pending slot value.
                const NO_PENDING: u32 = std.math.maxInt(u32);
                /// Zero-size payload slot: returned (aliased) by reads of
                /// ZST attributes, which carry no observable state.
                var zst_slot: E = undefined;
                /// Lazily appends the payload callbacks to the attribute
                /// registry on first queued command or filing.
                /// - `allocator` - funds the registry append.
                fn ensureRegistered(allocator: std.mem.Allocator) EcsError!void {
                    if (registered) {
                        return;
                    }
                    try Ecs.attribute_registry.append(allocator, .{
                        .name = @typeName(E),
                        .flush = flushPending,
                        .discardPending = discardPending,
                        .trimToLimits = trimToLimits,
                        .deinitStore = deinitStore,
                        .onEntityDestroyed = onEntityDestroyed,
                        .onEntityMigrated = onEntityMigrated,
                        .onDepthChanged = onDepthChanged,
                        .rebasePending = rebasePending,
                        .resetRegistered = resetRegistered,
                    });
                    registered = true;
                }
                /// Rewrites the entity generation on queued ops of one slot.
                /// Called when the entity migrates mid-flush, before the
                /// attribute flush runs: pending sets and destroys keep
                /// tracking the same logical entity under its new generation.
                /// Infallible: pure in-memory rewrite, no allocation.
                /// - `id` - migrated entity slot id.
                /// - `old_gen` - generation before the migrate.
                /// - `new_gen` - generation after the migrate.
                fn rebasePending(id: u32, old_gen: u8, new_gen: u8) void {
                    if (pending.items.len == 0) {
                        return;
                    }
                    for (pending.items) |*op| {
                        if (op.entity.id == id and op.entity.gen == old_gen) {
                            op.entity.gen = new_gen;
                        }
                    }
                }
                /// Marks the payload as unregistered, so a reused ECS after
                /// `deinit` registers it again on next use.
                fn resetRegistered() void {
                    registered = false;
                }
                /// Locates the committed page of one archetype.
                /// - `arch` - archetype id to look up.
                ///
                /// Returns `?usize` - position in `committed`, or null.
                fn findPageIndex(arch: u32) ?usize {
                    var low: usize = 0;
                    var high: usize = committed.items.len;
                    while (low < high) {
                        const mid: usize = low + (high - low) / 2;
                        const a: u32 = committed.items[mid].arch_id;
                        if (a < arch) {
                            low = mid + 1;
                        } else if (a > arch) {
                            high = mid;
                        } else {
                            return mid;
                        }
                    }
                    return null;
                }
                /// Finds the sorted insertion point of an archetype id.
                /// - `arch` - archetype id to insert.
                ///
                /// Returns `usize` - first page with `arch_id >= arch`.
                fn pageInsertIndex(arch: u32) usize {
                    var low: usize = 0;
                    var high: usize = committed.items.len;
                    while (low < high) {
                        const mid: usize = low + (high - low) / 2;
                        if (committed.items[mid].arch_id < arch) {
                            low = mid + 1;
                        } else {
                            high = mid;
                        }
                    }
                    return low;
                }
                /// Packs an archetype id plus a row into one slot-map link.
                /// - `arch` - archetype id (high 32 bits).
                /// - `row` - row position (low 32 bits).
                ///
                /// Returns `u64` - packed link.
                fn packRow(arch: u32, row: u32) u64 {
                    return (@as(u64, arch) << 32) | @as(u64, row);
                }
                /// Resolves a packed link to a live location. Packs store the
                /// immutable archetype id, so resolution re-searches by
                /// archetype and stays exact across page insert/drop;
                /// bounds-checked against row moves.
                /// - `link` - packed `(arch_id, row)` link.
                ///
                /// Returns `?Location` - live page and row, or null.
                fn resolvePacked(link: u64) ?Location {
                    const arch: u32 = @intCast(link >> 32);
                    const pi = findPageIndex(arch) orelse return null;
                    const row: u32 = @intCast(link & 0xFFFF_FFFF);
                    if (row >= committed.items[pi].entities.items.len) {
                        return null;
                    }
                    return .{ .page = pi, .index = row };
                }
                /// Grows the slot maps to cover one slot id, filling with
                /// empty sentinels. Each side grows independently, so a
                /// partial failure can never desynchronize them.
                /// - `allocator` - funds the growth.
                /// - `slot` - entity slot id that must be addressable.
                fn ensureSlot(allocator: std.mem.Allocator, slot: u32) EcsError!void {
                    const need: usize = @as(usize, slot) + 1;
                    if (need > rows.items.len) {
                        try rows.appendNTimes(allocator, NO_PACK, need - rows.items.len);
                    }
                    if (need > pending_rows.items.len) {
                        try pending_rows.appendNTimes(allocator, NO_PENDING, need - pending_rows.items.len);
                    }
                }
                /// Locates the committed row of one slot id plus generation.
                /// Single probe: upsert keeps one row per slot.
                /// - `id` - entity slot id.
                /// - `gen` - entity generation.
                ///
                /// Returns `?Location` - page and row, or null when absent.
                fn findSlotRow(id: u32, gen: u8) ?Location {
                    if (id >= rows.items.len) {
                        return null;
                    }
                    const link = rows.items[id];
                    if (link == NO_PACK) {
                        return null;
                    }
                    const loc = resolvePacked(link) orelse return null;
                    const e = committed.items[loc.page].entities.items[loc.index];
                    if (e.id == id and e.gen == gen) {
                        return loc;
                    }
                    return null;
                }
                /// Locates a committed attribute by entity reference.
                /// - `ref` - entity reference to look up.
                ///
                /// Returns `?Location` - page and row, or null when absent.
                fn findByEntity(ref: EntityReference) ?Location {
                    return findSlotRow(ref.id, ref.gen);
                }
                /// Returns the page index for one archetype, reusing a pooled
                /// shell when the page is new.
                /// - `allocator` - funds the page slot.
                /// - `arch` - archetype id to look up.
                ///
                /// Returns `usize` - position in `committed`.
                fn pageIndexFor(allocator: std.mem.Allocator, arch: u32) EcsError!usize {
                    if (findPageIndex(arch)) |pi| {
                        return pi;
                    }
                    const pos = pageInsertIndex(arch);
                    if (page_pool.pop()) |shell| {
                        try committed.insert(allocator, pos, shell);
                        committed.items[pos].arch_id = arch;
                    } else {
                        try committed.insert(allocator, pos, .{ .arch_id = arch });
                    }
                    return pos;
                }
                /// Appends a row and places it into the zone matching
                /// `depth`, keeping every zone contiguous and ordered.
                /// Typed adaptation of the component rotation: order inside a
                /// zone is irrelevant, so exactly one row per deeper zone
                /// moves via direct element swaps. Slot map entries of
                /// relocated rows are repaired; no entity columns are touched.
                /// - `allocator` - funds row and zone-list allocation.
                /// - `pi` - position of the page in `committed`.
                /// - `ref` - handle stored alongside the payload.
                /// - `value` - payload to store.
                /// - `depth` - hierarchy depth of the row.
                ///
                /// Returns `u32` - final position of the inserted row.
                fn insertRowAtDepth(
                    allocator: std.mem.Allocator,
                    pi: usize,
                    ref: EntityReference,
                    value: E,
                    depth: u32,
                ) EcsError!u32 {
                    const page = &committed.items[pi];
                    const arch = page.arch_id;
                    const at: u32 = @intCast(page.entities.items.len);
                    try page.entities.ensureTotalCapacity(allocator, page.entities.items.len + 1);
                    try page.values.ensureTotalCapacity(allocator, page.values.items.len + 1);
                    page.entities.appendAssumeCapacity(ref);
                    page.values.appendAssumeCapacity(value);
                    const idx = zoneInsertPosition(page.depth_zones.items, depth);
                    const zones = &page.depth_zones;
                    const has_zone = idx < zones.items.len and zones.items[idx].depth == depth;
                    const target: u32 = if (has_zone)
                        zones.items[idx].offset + zones.items[idx].len
                    else if (idx == 0)
                        0
                    else
                        zones.items[idx - 1].offset + zones.items[idx - 1].len;
                    const m: usize = if (has_zone)
                        zones.items.len - 1 - idx
                    else
                        zones.items.len - idx;
                    if (m > 0) {
                        const start = if (has_zone) idx + 1 else idx;
                        const tmp_e = page.entities.items[at];
                        const tmp_v = page.values.items[at];
                        const last_off: usize = zones.items[start + m - 1].offset;
                        page.entities.items[at] = page.entities.items[last_off];
                        page.values.items[at] = page.values.items[last_off];
                        var k: usize = m;
                        while (k > 1) : (k -= 1) {
                            const dst: usize = zones.items[start + k - 1].offset;
                            const src: usize = zones.items[start + k - 2].offset;
                            page.entities.items[dst] = page.entities.items[src];
                            page.values.items[dst] = page.values.items[src];
                        }
                        page.entities.items[zones.items[start].offset] = tmp_e;
                        page.values.items[zones.items[start].offset] = tmp_v;
                        rows.items[tmp_e.id] = packRow(arch, target);
                        rows.items[page.entities.items[at].id] = packRow(arch, at);
                        var j: usize = 1;
                        while (j <= m) : (j += 1) {
                            const pos: u32 = zones.items[start + j - 1].offset;
                            rows.items[page.entities.items[pos].id] = packRow(arch, pos);
                        }
                    } else {
                        rows.items[ref.id] = packRow(arch, at);
                    }
                    if (has_zone) {
                        zones.items[idx].len += 1;
                        for (idx + 1..zones.items.len) |z| {
                            zones.items[z].offset += 1;
                        }
                    } else {
                        try zones.insert(allocator, idx, .{
                            .depth = depth,
                            .offset = target,
                            .len = 1,
                        });
                        for (idx + 1..zones.items.len) |z| {
                            zones.items[z].offset += 1;
                        }
                    }
                    return target;
                }
                /// Removes the row at the given position from its depth zone.
                /// The zone tail swaps into the gap, then every deeper zone
                /// hands its tail upward, so exactly one row per deeper zone
                /// moves and the last overall row always holds the duplicate
                /// that `pop` drops. Slot map entries of every relocated row
                /// are repaired. Drops the page to the pool when empty.
                /// - `allocator` - funds the pool push of a dropped page.
                /// - `pi` - position of the page in `committed`.
                /// - `k` - row position inside the page.
                fn removeAt(allocator: std.mem.Allocator, pi: usize, k: usize) EcsError!void {
                    const page = &committed.items[pi];
                    const arch = page.arch_id;
                    const gone_id: u32 = page.entities.items[k].id;
                    const zi = zoneIndexForOffset(page.depth_zones.items, @intCast(k));
                    const zone = page.depth_zones.items[zi];
                    const e_d: usize = zone.offset + zone.len - 1;
                    if (k != e_d) {
                        page.entities.items[k] = page.entities.items[e_d];
                        page.values.items[k] = page.values.items[e_d];
                        rows.items[page.entities.items[k].id] = packRow(arch, @intCast(k));
                    }
                    const m: usize = page.depth_zones.items.len - 1 - zi;
                    if (m > 0) {
                        var dst: usize = e_d;
                        var i: usize = 1;
                        while (i <= m) : (i += 1) {
                            const src: usize = page.depth_zones.items[zi + i].offset +
                                page.depth_zones.items[zi + i].len - 1;
                            page.entities.items[dst] = page.entities.items[src];
                            page.values.items[dst] = page.values.items[src];
                            rows.items[page.entities.items[dst].id] = packRow(arch, @intCast(dst));
                            dst = src;
                        }
                    }
                    _ = page.entities.pop();
                    _ = page.values.pop();
                    page.depth_zones.items[zi].len -= 1;
                    for (zi + 1..page.depth_zones.items.len) |z| {
                        page.depth_zones.items[z].offset -= 1;
                    }
                    if (page.depth_zones.items[zi].len == 0) {
                        _ = page.depth_zones.orderedRemove(zi);
                    }
                    rows.items[gone_id] = NO_PACK;
                    if (page.entities.items.len == 0) {
                        const shell = committed.orderedRemove(pi);
                        try page_pool.append(allocator, shell);
                    }
                }
                /// Moves one row to another depth zone of the same page.
                /// - `allocator` - funds row allocation.
                /// - `pi` - position of the page in `committed`.
                /// - `k` - row position inside the page.
                /// - `new_depth` - hierarchy depth to move to.
                fn moveRowToDepth(
                    allocator: std.mem.Allocator,
                    pi: usize,
                    k: usize,
                    new_depth: u32,
                ) EcsError!void {
                    const arch = committed.items[pi].arch_id;
                    const ref = committed.items[pi].entities.items[k];
                    const v = committed.items[pi].values.items[k];
                    try removeAt(allocator, pi, k);
                    const npi = try pageIndexFor(allocator, arch);
                    _ = try insertRowAtDepth(allocator, npi, ref, v, new_depth);
                }
                /// Inserts or rewrites one committed entry in O(1) amortized:
                /// the slot map resolves to at most one row, updated in
                /// place, otherwise the row appends into the depth zone.
                /// - `allocator` - funds page and row allocation.
                /// - `arch` - archetype page to file under.
                /// - `ref` - entity carrying the attribute.
                /// - `value` - payload to store.
                /// - `depth` - hierarchy depth of the row.
                fn upsertBySlot(
                    allocator: std.mem.Allocator,
                    arch: u32,
                    ref: EntityReference,
                    value: E,
                    depth: u32,
                ) EcsError!void {
                    try ensureSlot(allocator, ref.id);
                    if (rows.items[ref.id] != NO_PACK) {
                        if (findSlotRow(ref.id, ref.gen)) |loc| {
                            committed.items[loc.page].entities.items[loc.index] = ref;
                            committed.items[loc.page].values.items[loc.index] = value;
                            return;
                        }
                    }
                    const pi = try pageIndexFor(allocator, arch);
                    _ = try insertRowAtDepth(allocator, pi, ref, value, depth);
                }
                /// Removes the committed entry of an entity reference.
                /// Silent when absent.
                /// - `allocator` - funds the pool push of a dropped page.
                /// - `ref` - entity reference to remove.
                fn removeBySlot(allocator: std.mem.Allocator, ref: EntityReference) EcsError!void {
                    const loc = findSlotRow(ref.id, ref.gen) orelse return;
                    try removeAt(allocator, loc.page, loc.index);
                }
                /// Queues a set command in O(1) amortized, rewriting a pending
                /// op for the same slot in place: a pending destroy becomes a
                /// set (the destroy is cancelled and the payload updated).
                /// The append is atomic: queue capacity is ensured first, so
                /// a failed grow cannot leave an unindexed entry behind.
                /// - `allocator` - funds the queue append.
                /// - `ref` - entity carrying the attribute.
                /// - `value` - payload to store.
                fn queueSet(allocator: std.mem.Allocator, ref: EntityReference, value: E) EcsError!void {
                    try ensureSlot(allocator, ref.id);
                    const slot = pending_rows.items[ref.id];
                    if (slot != NO_PENDING) {
                        pending.items[slot].entity = ref;
                        pending.items[slot].op = .{ .set = value };
                        return;
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + 1);
                    pending_rows.items[ref.id] = @intCast(pending.items.len);
                    pending.appendAssumeCapacity(.{ .entity = ref, .op = .{ .set = value } });
                }
                /// Queues a destroy command for a validated handle in O(1)
                /// amortized. A pending set for the same slot becomes a
                /// destroy (the set is cancelled); a pending destroy is a
                /// double destroy.
                /// - `allocator` - funds the queue append.
                /// - `handle` - handle issued by `AttributePage.handleAt`.
                fn queueDestroy(allocator: std.mem.Allocator, handle: AttributeHandle(E)) EcsError!void {
                    if (findByEntity(handle.entity) == null) {
                        return EcsError.AttributeNotFound;
                    }
                    try ensureSlot(allocator, handle.entity.id);
                    const slot = pending_rows.items[handle.entity.id];
                    if (slot != NO_PENDING) {
                        if (pending.items[slot].op == .destroy) {
                            return EcsError.AttributeHasPendingCommand;
                        }
                        pending.items[slot].op = .{ .destroy = {} };
                        return;
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + 1);
                    pending_rows.items[handle.entity.id] = @intCast(pending.items.len);
                    pending.appendAssumeCapacity(.{ .entity = handle.entity, .op = .{ .destroy = {} } });
                }
                /// Queues one payload for a whole slice of entities in O(n):
                /// every target is validated first, so a bad reference fails
                /// the batch before anything is queued. Capacity for the whole
                /// batch is reserved up front, then the loop itself cannot fail.
                /// - `allocator` - funds the queued ops.
                /// - `entities` - entities carrying the attribute.
                /// - `value` - payload stored with every attribute.
                fn queueSetMany(
                    allocator: std.mem.Allocator,
                    entities: []const EntityReference,
                    value: E,
                ) EcsError!void {
                    for (entities) |ref| {
                        try Ecs.validateSetTarget(ref);
                    }
                    for (entities) |ref| {
                        try ensureSlot(allocator, ref.id);
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + entities.len);
                    for (entities) |ref| {
                        const slot = pending_rows.items[ref.id];
                        if (slot != NO_PENDING) {
                            pending.items[slot].entity = ref;
                            pending.items[slot].op = .{ .set = value };
                        } else {
                            pending_rows.items[ref.id] = @intCast(pending.items.len);
                            pending.appendAssumeCapacity(.{ .entity = ref, .op = .{ .set = value } });
                        }
                    }
                }
                /// Queues one payload per entity, pairwise, in O(n). Same
                /// validate-first, reserve-up-front discipline as `queueSetMany`.
                /// - `allocator` - funds the queued ops.
                /// - `entities` - entities carrying the attributes.
                /// - `values` - payload per entity, same length as `entities`.
                fn queueSetEach(
                    allocator: std.mem.Allocator,
                    entities: []const EntityReference,
                    values: []const E,
                ) EcsError!void {
                    if (entities.len != values.len) {
                        return EcsError.CountMismatch;
                    }
                    for (entities) |ref| {
                        try Ecs.validateSetTarget(ref);
                    }
                    for (entities) |ref| {
                        try ensureSlot(allocator, ref.id);
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + entities.len);
                    for (entities, values) |ref, value| {
                        const slot = pending_rows.items[ref.id];
                        if (slot != NO_PENDING) {
                            pending.items[slot].entity = ref;
                            pending.items[slot].op = .{ .set = value };
                        } else {
                            pending_rows.items[ref.id] = @intCast(pending.items.len);
                            pending.appendAssumeCapacity(.{ .entity = ref, .op = .{ .set = value } });
                        }
                    }
                }
                /// Queues destroys for a slice of entities in O(n): every
                /// entry is validated first (present, not destroy-pending),
                /// so a bad entry fails the batch before anything is queued.
                /// A duplicated entity inside one call collapses silently;
                /// a repeated call reports `AttributeHasPendingCommand`.
                /// - `allocator` - funds the queued ops.
                /// - `entities` - entity references holding the attributes.
                fn queueDestroyMany(
                    allocator: std.mem.Allocator,
                    entities: []const EntityReference,
                ) EcsError!void {
                    for (entities) |e| {
                        if (findByEntity(e) == null) {
                            return EcsError.AttributeNotFound;
                        }
                        try ensureSlot(allocator, e.id);
                        const slot = pending_rows.items[e.id];
                        if (slot != NO_PENDING and pending.items[slot].op == .destroy) {
                            return EcsError.AttributeHasPendingCommand;
                        }
                    }
                    try pending.ensureTotalCapacity(allocator, pending.items.len + entities.len);
                    for (entities) |e| {
                        const slot = pending_rows.items[e.id];
                        if (slot != NO_PENDING) {
                            if (pending.items[slot].op == .destroy) {
                                continue;
                            }
                            pending.items[slot].op = .{ .destroy = {} };
                        } else {
                            pending_rows.items[e.id] = @intCast(pending.items.len);
                            pending.appendAssumeCapacity(.{ .entity = e, .op = .{ .destroy = {} } });
                        }
                    }
                }
                /// Arms a bulk wipe: O(1), no queue traffic. The flush drops
                /// every committed page to the pool instead of removing rows
                /// one by one; only ops queued after this call survive it.
                /// Idempotent within one system.
                fn queueDestroyAll() void {
                    wipe_mark = pending.items.len;
                    wiped = true;
                }
                /// Moves the pending queue into committed pages, resolving
                /// every set under the entity live archetype and depth.
                /// Stale sets (dead or recycled slots) and stale destroys are
                /// skipped silently, mirroring entity flush semantics. The
                /// pending slot map resets inline, so no second pass is needed.
                /// - `allocator` - funds page and row allocation.
                fn flushPending(allocator: std.mem.Allocator) EcsError!void {
                    defer {
                        pending.clearRetainingCapacity();
                        wiped = false;
                    }
                    var start: usize = 0;
                    if (wiped) {
                        for (rows.items) |*r| {
                            r.* = NO_PACK;
                        }
                        try page_pool.ensureTotalCapacity(allocator, page_pool.items.len + committed.items.len);
                        for (committed.items) |*page| {
                            page.entities.items.len = 0;
                            page.values.items.len = 0;
                            page.depth_zones.items.len = 0;
                            page_pool.appendAssumeCapacity(page.*);
                        }
                        committed.clearRetainingCapacity();
                        for (pending.items[0..wipe_mark]) |op| {
                            pending_rows.items[op.entity.id] = NO_PENDING;
                        }
                        start = wipe_mark;
                    }
                    for (pending.items[start..]) |op| {
                        pending_rows.items[op.entity.id] = NO_PENDING;
                        switch (op.op) {
                            .set => |v| {
                                const id: u32 = op.entity.id;
                                if (id >= Ecs.entity_generation.items.len) {
                                    continue;
                                }
                                // Generations match or the op was rebased by a
                                // same-flush migrate; anything else is stale
                                // (the entity died and its slot can't have been
                                // recycled yet: recycling needs a create, and
                                // creates reserve fresh ids or ids freed by
                                // earlier flushes, never this one).
                                if (Ecs.entity_generation.items[id] != op.entity.gen) {
                                    continue;
                                }
                                if (!op.entity.isAlive()) {
                                    continue;
                                }
                                const arch: u32 = Ecs.entity_archetype.items[id];
                                const depth: u32 = Ecs.entity_depth.items[id];
                                try upsertBySlot(allocator, arch, op.entity, v, depth);
                            },
                            .destroy => {
                                try removeBySlot(allocator, op.entity);
                            },
                        }
                    }
                }
                /// Drops the pending queue without applying it. Also disarms
                /// a bulk wipe queued by the failing system.
                fn discardPending() void {
                    for (pending.items) |op| {
                        pending_rows.items[op.entity.id] = NO_PENDING;
                    }
                    pending.clearRetainingCapacity();
                    wiped = false;
                    wipe_mark = 0;
                }
                /// Trims assigned budgets back toward their targets. Runs at
                /// frame end (there is no auto-clear for attributes); skips
                /// clean stores. Same 2x-tolerance rule as events.
                /// - `allocator` - funds pool reservations on trim.
                fn trimToLimits(allocator: std.mem.Allocator) EcsError!void {
                    if (limits.pages) |pg| {
                        const max_shells: usize = pg;
                        while (page_pool.items.len > max_shells) {
                            var shell = page_pool.pop().?;
                            shell.entities.deinit(allocator);
                            shell.values.deinit(allocator);
                            shell.depth_zones.deinit(allocator);
                        }
                        // Only when empty: live pages must never lose their shell.
                        if (committed.items.len == 0 and committed.capacity > 2 * max_shells) {
                            committed.deinit(allocator);
                            committed = .empty;
                            try committed.ensureTotalCapacity(allocator, max_shells);
                        }
                    }
                    if (limits.events_per_page) |ec| {
                        const cap: usize = ec;
                        for (page_pool.items) |*shell| {
                            if (shell.entities.capacity > 2 * cap) {
                                shell.entities.deinit(allocator);
                                shell.entities = .empty;
                                try shell.entities.ensureTotalCapacity(allocator, cap);
                            }
                            if (shell.values.capacity > 2 * cap) {
                                shell.values.deinit(allocator);
                                shell.values = .empty;
                                try shell.values.ensureTotalCapacity(allocator, cap);
                            }
                        }
                    }
                    if (limits.pending) |pcap| {
                        const cap: usize = pcap;
                        if (pending.capacity > 2 * cap) {
                            pending.deinit(allocator);
                            pending = .empty;
                            try pending.ensureTotalCapacity(allocator, cap);
                        }
                    }
                    if (limits.slots) |sc| {
                        // Live length is the floor: slot coverage never drops,
                        // and live packs are preserved by shrinking in place.
                        const floor: usize = @max(rows.items.len, sc);
                        if (rows.capacity > 2 * floor) {
                            rows.shrinkAndFree(allocator, rows.items.len);
                        }
                        const pfloor: usize = @max(pending_rows.items.len, sc);
                        if (pending_rows.capacity > 2 * pfloor) {
                            pending_rows.shrinkAndFree(allocator, pending_rows.items.len);
                        }
                    }
                }
                /// Frees committed pages, pooled shells, queues and slot maps.
                /// - `allocator` - allocator that funded the store.
                fn deinitStore(allocator: std.mem.Allocator) void {
                    for (committed.items) |*page| {
                        page.entities.deinit(allocator);
                        page.values.deinit(allocator);
                        page.depth_zones.deinit(allocator);
                    }
                    committed.deinit(allocator);
                    committed = .empty;
                    for (page_pool.items) |*page| {
                        page.entities.deinit(allocator);
                        page.values.deinit(allocator);
                        page.depth_zones.deinit(allocator);
                    }
                    page_pool.deinit(allocator);
                    page_pool = .empty;
                    pending.deinit(allocator);
                    pending = .empty;
                    rows.deinit(allocator);
                    rows = .empty;
                    pending_rows.deinit(allocator);
                    pending_rows = .empty;
                }
                /// Purges the committed row of one destroyed slot in O(1).
                /// Single probe: upsert keeps one row per slot.
                /// - `id` - destroyed entity slot id.
                /// - `allocator` - funds the pool push of a dropped page.
                fn onEntityDestroyed(id: u32, allocator: std.mem.Allocator) EcsError!void {
                    if (id >= rows.items.len) {
                        return;
                    }
                    const live: u8 = Ecs.entity_generation.items[id];
                    const link = rows.items[id];
                    if (link == NO_PACK) {
                        return;
                    }
                    const loc = resolvePacked(link) orelse return;
                    const e = committed.items[loc.page].entities.items[loc.index];
                    if (e.id == id and e.gen == live) {
                        try removeAt(allocator, loc.page, loc.index);
                    }
                }
                /// Relocates one entity row to the destination archetype page
                /// at the unchanged depth, refreshing its generation.
                /// - `id` - migrated entity slot id.
                /// - `old_arch` - archetype id the entity leaves.
                /// - `new_arch` - archetype id the entity enters.
                /// - `new_gen` - generation after the migrate.
                /// - `allocator` - funds the destination page slot.
                fn onEntityMigrated(
                    id: u32,
                    old_arch: u32,
                    new_arch: u32,
                    new_gen: u8,
                    allocator: std.mem.Allocator,
                ) EcsError!void {
                    if (id >= rows.items.len) {
                        return;
                    }
                    _ = old_arch;
                    const old_gen: u8 = new_gen -% 1;
                    const loc = findSlotRow(id, old_gen) orelse return;
                    const page = &committed.items[loc.page];
                    const v = page.values.items[loc.index];
                    const zi = zoneIndexForOffset(page.depth_zones.items, @intCast(loc.index));
                    const depth = page.depth_zones.items[zi].depth;
                    try removeAt(allocator, loc.page, loc.index);
                    const fresh = EntityReference{ .id = @intCast(id), .gen = new_gen };
                    const npi = try pageIndexFor(allocator, new_arch);
                    _ = try insertRowAtDepth(allocator, npi, fresh, v, depth);
                }
                /// Moves one entity row to the zone of its new depth after a
                /// reparent. Silent when the entity carries no attribute.
                /// - `id` - reparented entity slot id.
                /// - `new_depth` - hierarchy depth after the move.
                /// - `allocator` - funds row allocation.
                fn onDepthChanged(id: u32, new_depth: u32, allocator: std.mem.Allocator) EcsError!void {
                    if (id >= rows.items.len) {
                        return;
                    }
                    const link = rows.items[id];
                    if (link == NO_PACK) {
                        return;
                    }
                    const loc = resolvePacked(link) orelse return;
                    try moveRowToDepth(allocator, loc.page, loc.index, new_depth);
                }
            };
        }
        /// Filtered view over one attribute payload committed pages: the
        /// comptime `pages()` match intersected with the sparse page list in
        /// one merge pass. Both sides are ascending by archetype id, so the
        /// result is dense and sorted without any search.
        /// - `E` - attribute payload type.
        /// - `include` - component bundle that must be present.
        /// - `exclude` - component bundle that must be absent.
        ///
        /// Returns `type` - filter namespace with a single `filter` function.
        /// Private: filters are only issued by `SystemHandler`.
        fn AttributeFilter(comptime E: type, comptime include: anytype, comptime exclude: anytype) type {
            const Container = PagesContainer(include, exclude);
            const container: Container = .{};
            const matched_pages = container.allPages();
            return struct {
                /// Per-filter static scratch for the dense prefix. Same
                /// lifetime rule as `nonEmptyPages`: valid until the next
                /// `filterAttributes` call for the same payload and query.
                var buf: [matched_pages.len]AttributePage(E) = undefined;
                /// Intersects the query match with committed pages.
                ///
                /// Returns `[]const AttributePage(E)` - matching pages, dense.
                fn filter() []const AttributePage(E) {
                    const pages = AttributeStore(E).committed.items;
                    var total: usize = 0;
                    var i: usize = 0;
                    var j: usize = 0;
                    while (i < matched_pages.len and j < pages.len) {
                        const a: u32 = matched_pages[i].arch_id;
                        const b: u32 = pages[j].arch_id;
                        if (a == b) {
                            buf[total] = pages[j];
                            total += 1;
                            i += 1;
                            j += 1;
                        } else if (a < b) {
                            i += 1;
                        } else {
                            j += 1;
                        }
                    }
                    return buf[0..total];
                }
            };
        }
        /// Type-erased per-payload callbacks of the attribute subsystem.
        /// Separate registry from events: attributes persist (no frame-end
        /// clear), so they carry a trim hook instead, plus a depth hook
        /// that events have no use for.
        const AttributeRegistryEntry = struct {
            /// Payload type name, for debuggers only.
            name: []const u8,
            /// Moves the payload pending queue into committed pages.
            flush: *const fn (std.mem.Allocator) EcsError!void,
            /// Drops the payload pending queue without applying it.
            discardPending: *const fn () void,
            /// Trims assigned budgets back toward their targets.
            trimToLimits: *const fn (std.mem.Allocator) EcsError!void,
            /// Frees committed pages and the pending queue.
            deinitStore: *const fn (std.mem.Allocator) void,
            /// Purges the committed row of one destroyed entity slot.
            onEntityDestroyed: *const fn (u32, std.mem.Allocator) EcsError!void,
            /// Moves one entity row to the destination archetype page.
            onEntityMigrated: *const fn (u32, u32, u32, u8, std.mem.Allocator) EcsError!void,
            /// Moves one entity row to the zone of its new depth.
            onDepthChanged: *const fn (u32, u32, std.mem.Allocator) EcsError!void,
            /// Rewrites the entity generation on queued ops of one slot.
            /// Runs when the entity migrates mid-flush, before the attribute
            /// flush: pending ops keep tracking the same logical entity.
            rebasePending: *const fn (u32, u8, u8) void,
            /// Marks the payload store as unregistered, so a reused ECS
            /// registers it again after `deinit`.
            resetRegistered: *const fn () void,
        };
        /// Every attribute payload type with queued commands in any frame so far.
        var attribute_registry: std.ArrayListUnmanaged(AttributeRegistryEntry) = .empty;
        /// Applies every queued attribute command, payload by payload. Runs
        /// after the entity commands of the same flush: reserved slots are
        /// materialized by then, so sets file under the live archetype and
        /// depth straight away, with no relocation step.
        /// - `allocator` - funds page and row allocation.
        fn flushAttributePending(allocator: std.mem.Allocator) EcsError!void {
            for (Ecs.attribute_registry.items) |entry| {
                try entry.flush(allocator);
            }
        }
        /// Drops every queued attribute command without applying it.
        /// Committed attributes of earlier systems stay untouched.
        fn discardAttributePending() void {
            for (Ecs.attribute_registry.items) |entry| {
                entry.discardPending();
            }
        }
        /// Trims assigned budgets of every attribute payload, payload by
        /// payload. Runs once after the last system of a successful schedule
        /// (attributes have no auto-clear to piggyback on). Skipped entirely
        /// when no attribute type was ever registered.
        /// - `allocator` - funds pool reservations on trim.
        fn trimAttributes(allocator: std.mem.Allocator) EcsError!void {
            if (Ecs.attribute_registry.items.len == 0) {
                return;
            }
            for (Ecs.attribute_registry.items) |entry| {
                try entry.trimToLimits(allocator);
            }
        }
        /// Purges committed attributes of one destroyed slot, payload by
        /// payload. Skipped entirely when no attribute type was ever registered.
        /// - `id` - destroyed entity slot id.
        /// - `allocator` - funds the pool push of a dropped page.
        fn notifyAttributeDestroyed(id: u32, allocator: std.mem.Allocator) EcsError!void {
            if (Ecs.attribute_registry.items.len == 0) {
                return;
            }
            for (Ecs.attribute_registry.items) |entry| {
                try entry.onEntityDestroyed(id, allocator);
            }
        }
        /// Relocates committed attributes of one migrated entity, payload by
        /// payload. Skipped entirely when no attribute type was ever registered.
        /// - `id` - migrated entity slot id.
        /// - `old_arch` - archetype id the entity leaves.
        /// - `new_arch` - archetype id the entity enters.
        /// - `new_gen` - generation after the migrate.
        /// - `allocator` - funds the destination page slot.
        fn notifyAttributeMigrated(
            id: u32,
            old_arch: u32,
            new_arch: u32,
            new_gen: u8,
            allocator: std.mem.Allocator,
        ) EcsError!void {
            if (Ecs.attribute_registry.items.len == 0) {
                return;
            }
            for (Ecs.attribute_registry.items) |entry| {
                try entry.onEntityMigrated(id, old_arch, new_arch, new_gen, allocator);
            }
        }
        /// Rewrites the entity generation on queued attribute ops of one
        /// slot, payload by payload. Called when the entity migrates
        /// mid-flush, before the attribute flush runs. Skipped entirely when
        /// no attribute type was ever registered.
        /// - `id` - migrated entity slot id.
        /// - `old_gen` - generation before the migrate.
        /// - `new_gen` - generation after the migrate.
        fn rebaseAttributePending(id: u32, old_gen: u8, new_gen: u8) void {
            if (Ecs.attribute_registry.items.len == 0) {
                return;
            }
            for (Ecs.attribute_registry.items) |entry| {
                entry.rebasePending(id, old_gen, new_gen);
            }
        }
        /// Moves committed attributes of one reparented entity to the zone
        /// of its new depth, payload by payload. Skipped entirely when no
        /// attribute type was ever registered.
        /// - `id` - reparented entity slot id.
        /// - `new_depth` - hierarchy depth after the move.
        /// - `allocator` - funds row allocation.
        fn notifyAttributeDepthChanged(id: u32, new_depth: u32, allocator: std.mem.Allocator) EcsError!void {
            if (Ecs.attribute_registry.items.len == 0) {
                return;
            }
            for (Ecs.attribute_registry.items) |entry| {
                try entry.onDepthChanged(id, new_depth, allocator);
            }
        }
        /// Filtered view over one payload committed pages: the comptime
        /// `pages()` match intersected with the sparse page list in one merge
        /// pass. Both sides are ascending by archetype id, so the result is
        /// dense and sorted without any search.
        /// - `E` - event payload type.
        /// - `include` - component bundle that must be present.
        /// - `exclude` - component bundle that must be absent.
        ///
        /// Returns `type` - filter namespace with a single `filter` function.
        /// Private: filters are only issued by `SystemHandler`.
        fn EventFilter(comptime E: type, comptime include: anytype, comptime exclude: anytype) type {
            const Container = PagesContainer(include, exclude);
            const container: Container = .{};
            const matched_pages = container.allPages();
            return struct {
                /// Per-filter static scratch for the dense prefix. Same
                /// lifetime rule as `nonEmptyPages`: valid until the next
                /// `filterEvents` call for the same payload and query.
                var buf: [matched_pages.len]EventPage(E) = undefined;
                /// Intersects the query match with committed pages.
                ///
                /// Returns `[]const EventPage(E)` - matching pages, dense.
                fn filter() []const EventPage(E) {
                    const pages = EventStore(E).committed.items;
                    var total: usize = 0;
                    var i: usize = 0;
                    var j: usize = 0;
                    while (i < matched_pages.len and j < pages.len) {
                        const a: u32 = matched_pages[i].arch_id;
                        const b: u32 = pages[j].arch_id;
                        if (a == b) {
                            buf[total] = pages[j];
                            total += 1;
                            i += 1;
                            j += 1;
                        } else if (a < b) {
                            i += 1;
                        } else {
                            j += 1;
                        }
                    }
                    return buf[0..total];
                }
            };
        }
        /// Type-erased per-payload callbacks. One entry per event payload
        /// type with ever-queued commands; the entry is appended lazily on
        /// first use, so payloads that are only read never register.
        const EventRegistryEntry = struct {
            /// Payload type name, for debuggers only.
            name: []const u8,
            /// Moves the payload pending queue into committed pages.
            flush: *const fn (std.mem.Allocator) EcsError!void,
            /// Drops the payload pending queue without applying it.
            discardPending: *const fn () void,
            /// Clears committed pages into the pool, retaining buffers.
            clearCommitted: *const fn (std.mem.Allocator) EcsError!void,
            /// Frees committed pages and the pending queue.
            deinitStore: *const fn (std.mem.Allocator) void,
            /// Purges every committed entry of one destroyed entity slot.
            onEntityDestroyed: *const fn (u32, std.mem.Allocator) EcsError!void,
            /// Moves one entity entries to the destination archetype page.
            onEntityMigrated: *const fn (u32, u32, u32, u8, std.mem.Allocator) EcsError!void,
            /// Marks the payload store as unregistered, so a reused ECS
            /// registers it again after `deinit`.
            resetRegistered: *const fn () void,
        };
        /// Every event payload type with queued commands in any frame so far.
        var event_registry: std.ArrayListUnmanaged(EventRegistryEntry) = .empty;
        /// Applies every queued event command, payload by payload. Runs
        /// before the entity commands of the same flush: sets file under the
        /// pre-command archetype, then queued migrates relocate them and
        /// queued destroys purge them, so an event always follows its entity
        /// within one flush.
        /// - `allocator` - funds page and row allocation.
        fn flushEventPending(allocator: std.mem.Allocator) EcsError!void {
            for (Ecs.event_registry.items) |entry| {
                try entry.flush(allocator);
            }
        }
        /// Drops every queued event command without applying it. Committed
        /// events of earlier systems stay untouched.
        fn discardEventPending() void {
            for (Ecs.event_registry.items) |entry| {
                entry.discardPending();
            }
        }
        /// Clears every committed event page into its pool, retaining all
        /// buffers. Runs once after the last system of a successful
        /// schedule: events live for exactly one frame. Skips stores that
        /// filed nothing. Steady-state frames allocate nothing here.
        /// - `allocator` - funds the one-time pool reservation.
        fn clearAllEvents(allocator: std.mem.Allocator) EcsError!void {
            for (Ecs.event_registry.items) |entry| {
                try entry.clearCommitted(allocator);
            }
        }
        /// Purges committed events of one destroyed slot, payload by payload.
        /// Skipped entirely when no event type was ever registered.
        /// - `id` - destroyed entity slot id.
        /// - `allocator` - funds moved-row index updates and frees emptied pages.
        fn notifyEventEntityDestroyed(id: u32, allocator: std.mem.Allocator) EcsError!void {
            if (Ecs.event_registry.items.len == 0) {
                return;
            }
            for (Ecs.event_registry.items) |entry| {
                try entry.onEntityDestroyed(id, allocator);
            }
        }
        /// Relocates committed events of one migrated entity to the
        /// destination archetype page and refreshes their generation.
        /// Skipped entirely when no event type was ever registered.
        /// - `id` - migrated entity slot id.
        /// - `old_arch` - archetype id the entity leaves.
        /// - `new_arch` - archetype id the entity enters.
        /// - `new_gen` - generation after the migrate.
        /// - `allocator` - funds the destination page slot.
        fn notifyEventEntityMigrated(
            id: u32,
            old_arch: u32,
            new_arch: u32,
            new_gen: u8,
            allocator: std.mem.Allocator,
        ) EcsError!void {
            if (Ecs.event_registry.items.len == 0) {
                return;
            }
            for (Ecs.event_registry.items) |entry| {
                try entry.onEntityMigrated(id, old_arch, new_arch, new_gen, allocator);
            }
        }
        /// Handle passed to every system function. It is the only way to read
        /// page data and the only way to schedule structural changes.
        /// Data obtained through the handler (pointers, slices, pages) is valid
        /// only until the current system returns: queued commands are applied
        /// between systems and may reallocate storages.
        pub const SystemHandler = struct {
            /// Allocator funding the command queue and flushed changes.
            allocator: std.mem.Allocator,
            /// Builds a container of pages for archetypes containing all `include`
            /// components and none of the `exclude` components.
            /// - `self` - handler of the running system.
            /// - `include` - component bundle that must be present.
            /// - `exclude` - component bundle that must be absent. `null` and empty
            ///   bundles are equivalent to no exclusion.
            ///
            /// Returns `PagesContainer` - zero-sized value; call `allPages()`
            /// or `nonEmptyPages()` on it, including on a temporary.
            pub fn pages(
                self: *const SystemHandler,
                comptime include: anytype,
                comptime exclude: anytype,
            ) PagesContainer(include, exclude) {
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
                for (self.pages(include, exclude).nonEmptyPages()) |p| {
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
            /// Queues entity creation and returns the future handle. The id
            /// and generation are reserved immediately (the slot is marked
            /// `pending_create`), so the returned reference can already be
            /// used as a parent for `cmdCreateChild`/`cmdCreateChildren`
            /// queued later in the same system. The entity itself - storage
            /// row, components, hierarchy - is created at flush.
            /// Until then `isAlive()` returns false and every read on the
            /// reference fails with `EntityIsNotAlive`.
            /// - `self` - handler of the running system.
            /// - `bundle` - component bundle of the new entity. Must be declared in `ECS(...)`.
            /// - `values` - tuple of component values, one per bundle component,
            ///   in any order. Types must match the bundle exactly.
            ///
            /// Returns `EntityReference` - reserved handle, alive after flush.
            pub fn cmdCreate(
                self: *const SystemHandler,
                comptime bundle: anytype,
                values: anytype,
            ) EcsError!EntityReference {
                const arch = comptime archetypeId(bundle);
                const blob = try Ecs.packValues(arch, values, self.allocator);
                errdefer self.allocator.free(blob);
                const reservation = try Ecs.reserveSlot(self.allocator, @intCast(arch));
                errdefer Ecs.releaseReservation(self.allocator, reservation) catch {};
                try Ecs.commands.append(self.allocator, .{ .create = .{
                    .arch = @intCast(arch),
                    .bytes = blob,
                    .reserved = reservation.ref,
                    .from_free = reservation.from_free,
                } });
                return reservation.ref;
            }
            /// Queues creation of `n` entities with identical component values
            /// and returns the slice of their reserved handles. All slots are
            /// reserved immediately (one batch command): rows are appended in
            /// one go and the depth zones are consolidated with a single pass
            /// instead of paying the per-row cascade `n` times.
            /// The returned slice is owned by the queued command and stays
            /// valid until the batch flushes or is discarded; use it for
            /// chaining `cmdCreateChild` in the same system.
            /// - `self` - handler of the running system.
            /// - `bundle` - component bundle of the new entities.
            /// - `values` - tuple of component values shared by all `n` entities.
            /// - `n` - number of entities to create.
            ///
            /// Returns `[]const EntityReference` - reserved handles.
            pub fn cmdCreateN(
                self: *const SystemHandler,
                comptime bundle: anytype,
                values: anytype,
                n: u32,
            ) EcsError![]const EntityReference {
                const arch: u32 = @intCast(comptime archetypeId(bundle));
                return self.queueCreateMany(
                    arch,
                    values,
                    n,
                    null,
                );
            }
            /// Queues creation of `n` entities attached to `parent` in one
            /// batch and returns their reserved handles. Identical to
            /// `cmdCreateN` except every entity is born as a child: its depth
            /// is `parent.depth + 1` and it is linked into the parent's child
            /// list during the same flush.
            /// - `self` - handler of the running system.
            /// - `parent` - parent entity. Must be alive and idle at queue
            ///   time, or reserved by an earlier `cmdCreate` in this system.
            /// - `bundle` - component bundle of the new entities.
            /// - `values` - tuple of component values shared by all `n` entities.
            /// - `n` - number of entities to create.
            ///
            /// Returns `[]const EntityReference` - reserved handles.
            pub fn cmdCreateChildren(
                self: *const SystemHandler,
                parent: EntityReference,
                comptime bundle: anytype,
                values: anytype,
                n: u32,
            ) EcsError![]const EntityReference {
                try Ecs.requireParent(parent);
                const arch: u32 = @intCast(comptime archetypeId(bundle));
                return self.queueCreateMany(
                    arch,
                    values,
                    n,
                    parent,
                );
            }
            /// Queues creation of an entity attached to `parent` and returns
            /// its reserved handle. The child is reserved immediately; during
            /// flush its depth becomes `parent.depth + 1` and it is linked
            /// into the parent's child list, so no intermediate root state is
            /// ever observable. `parent` may be alive and idle, or reserved
            /// by an earlier `cmdCreate` in this system.
            /// - `self` - handler of the running system.
            /// - `parent` - parent entity. Must be alive and idle at queue
            ///   time, or reserved by an earlier `cmdCreate` in this system.
            /// - `bundle` - component bundle of the new entity.
            /// - `values` - tuple of component values matching the bundle.
            ///
            /// Returns `EntityReference` - reserved handle, alive after flush.
            pub fn cmdCreateChild(
                self: *const SystemHandler,
                parent: EntityReference,
                comptime bundle: anytype,
                values: anytype,
            ) EcsError!EntityReference {
                try Ecs.requireParent(parent);
                const arch = comptime archetypeId(bundle);
                const blob = try Ecs.packValues(arch, values, self.allocator);
                errdefer self.allocator.free(blob);
                const reservation = try Ecs.reserveSlot(self.allocator, @intCast(arch));
                errdefer Ecs.releaseReservation(self.allocator, reservation) catch {};
                try Ecs.commands.append(self.allocator, .{ .create_child = .{
                    .arch = @intCast(arch),
                    .bytes = blob,
                    .parent = parent,
                    .reserved = reservation.ref,
                    .from_free = reservation.from_free,
                } });
                return reservation.ref;
            }
            /// Shared implementation of `cmdCreateN` and `cmdCreateChildren`:
            /// packs one value blob, reserves `n` slots, queues a single batch
            /// command and returns the slice of reserved handles. When
            /// `parent` is non-null the batch command is `create_children`.
            /// - `self` - handler of the running system.
            /// - `arch` - destination archetype id.
            /// - `values` - tuple of component values shared by all entities.
            /// - `n` - number of entities to create.
            /// - `parent` - optional parent for `create_children`.
            ///
            /// Returns `[]const EntityReference` - reserved handles, owned by
            /// the queued command until flush.
            fn queueCreateMany(
                self: *const SystemHandler,
                comptime arch: u32,
                values: anytype,
                n: u32,
                parent: ?EntityReference,
            ) EcsError![]const EntityReference {
                const blob = try Ecs.packValues(arch, values, self.allocator);
                errdefer self.allocator.free(blob);
                const reserved = try self.allocator.alloc(EntityReference, n);
                errdefer self.allocator.free(reserved);
                const from_free = try self.allocator.alloc(bool, n);
                errdefer self.allocator.free(from_free);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const reservation = try Ecs.reserveSlot(self.allocator, arch);
                    reserved[i] = reservation.ref;
                    from_free[i] = reservation.from_free;
                }
                errdefer {
                    var j: u32 = n;
                    while (j > 0) {
                        j -= 1;
                        Ecs.releaseReservation(
                            self.allocator,
                            .{ .ref = reserved[j], .from_free = from_free[j] },
                        ) catch {};
                    }
                }
                if (parent) |p| {
                    try Ecs.commands.append(self.allocator, .{ .create_children = .{
                        .arch = arch,
                        .bytes = blob,
                        .parent = p,
                        .reserved = reserved,
                        .from_free = from_free,
                    } });
                } else {
                    try Ecs.commands.append(self.allocator, .{ .create_batch = .{
                        .arch = arch,
                        .bytes = blob,
                        .reserved = reserved,
                        .from_free = from_free,
                    } });
                }
                return reserved;
            }
            /// Queues reparenting of `ref` under `parent`, or detaching it
            /// when `parent` is null. The queued parent is written to
            /// `entity_pending_parent` immediately and the full cycle check
            /// runs against the effective hierarchy (pending parents of other
            /// queued reparents included), so batch cycles like
            /// `A->B; B->A` fail here, not at flush.
            /// The slot becomes pending: a second reparent, a destroy or a
            /// migrate of the same entity in this batch is rejected with
            /// `EntityHasPendingCommand`.
            /// - `self` - handler of the running system.
            /// - `ref` - entity to move. Must be alive and idle.
            /// - `parent` - new parent, or null to detach. Must be alive.
            pub fn cmdReparent(
                self: *const SystemHandler,
                ref: EntityReference,
                parent: ?EntityReference,
            ) EcsError!void {
                const entity_index = try Ecs.requireIdle(ref);
                var parent_id: u32 = NO_ENTITY;
                if (parent) |p| {
                    if (!p.isAlive()) {
                        return EcsError.EntityIsNotAlive;
                    }
                    if (p.id == ref.id) {
                        return EcsError.HierarchyCycle;
                    }
                    // Walk the effective parent chain: queued reparents are
                    // treated as applied, so a cycle that only exists after
                    // the whole batch is rejected right here.
                    var cur: u32 = p.id;
                    while (cur != NO_ENTITY) {
                        if (cur == ref.id) {
                            return EcsError.HierarchyCycle;
                        }
                        cur = Ecs.effectiveParent(cur);
                    }
                    parent_id = p.id;
                }
                try Ecs.commands.append(self.allocator, .{ .reparent = .{
                    .ref = ref,
                    .parent = parent,
                } });
                Ecs.setEntityState(entity_index, .{ .pending_reparent = true });
                Ecs.entity_pending_parent.items[entity_index] = parent_id;
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
                Ecs.setEntityState(entity_index, .{ .pending_destroy = true });
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
                Ecs.setEntityState(entity_index, .{ .pending_migrate = true });
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
                for (self.pages(include, exclude).allPages()) |p| {
                    for (p.entities()) |ref| {
                        const entity_index = try Ecs.requireIdle(ref);
                        try Ecs.commands.append(self.allocator, .{ .destroy = ref });
                        Ecs.setEntityState(entity_index, .{ .pending_destroy = true });
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
                @setEvalBranchQuota(10_000_000);
                const id: u32 = @intCast(comptime archetypeId(bundle));
                for (Ecs.storages[id].refs.items) |ref| {
                    const entity_index = try Ecs.requireIdle(ref);
                    Ecs.setEntityState(entity_index, .{ .pending_destroy = true });
                }
                try Ecs.commands.append(self.allocator, .{ .destroy_page = id });
            }
            /// Queues an event for the entity, creating it when absent and
            /// overwriting the payload when present (upsert). Applied at the
            /// next flush and visible to the following system. A repeated
            /// `cmdSetEvent` for the same slot in one system rewrites the
            /// queued payload instead of duplicating the event. Does not mark
            /// the entity pending: entity commands stay independent. Accepts
            /// live entities and slots reserved by `cmdCreate` in the same
            /// system; rejects destroy-pending slots. Returns no handle:
            /// handles come only from `allEvents`/`filterEvents` pages.
            /// - `self` - handler of the running system.
            /// - `ref` - entity carrying the event.
            /// - `E` - event payload struct type. Needs no `ECS(...)` declaration.
            /// - `value` - payload stored with the event.
            pub fn cmdSetEvent(
                self: *const SystemHandler,
                ref: EntityReference,
                comptime E: type,
                value: E,
            ) EcsError!void {
                validateEventType(E);
                const Store = EventStore(E);
                try Store.ensureRegistered(self.allocator);
                try Ecs.validateSetTarget(ref);
                try Store.queueSet(self.allocator, ref, value);
            }
            /// Queues destruction of the event behind the handle. Handles come
            /// only from `EventPage.handleAt`, so both misuse cases are
            /// observable: unknown or already gone events fail with
            /// `EventNotFound`, a second destroy queued in the same system
            /// fails with `EventHasPendingCommand`. Handles of one
            /// `(entity, generation)` pair are aliases when lifecycle history
            /// duplicated the row: destroying one destroys them all. Each
            /// destroy costs one lookup; to wipe everything you read, prefer
            /// a single `cmdDestroyEvents` instead of a per-handle loop.
            /// - `self` - handler of the running system.
            /// - `handle` - handle issued by `allEvents`/`filterEvents` pages.
            pub fn cmdDestroyEvent(self: *const SystemHandler, handle: anytype) EcsError!void {
                const HT = @TypeOf(handle);
                if (!@hasDecl(HT, "EventPayload")) {
                    @compileError("cmdDestroyEvent expects an EventHandle(E) from EventPage.handleAt().");
                }
                const E = HT.EventPayload;
                if (HT != EventHandle(E)) {
                    @compileError("cmdDestroyEvent expects an EventHandle(E) from EventPage.handleAt().");
                }
                validateEventType(E);
                const Store = EventStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueDestroy(self.allocator, handle);
            }
            /// Queues destruction of every event of the payload type in O(1):
            /// arms a bulk wipe that the flush applies in O(pages), dropping
            /// whole pages to the pool instead of removing rows one by one.
            /// Pending sets convert implicitly (they die with the wipe), so
            /// only sets queued after this call survive the flush. No-op
            /// when nothing was ever queued for the payload.
            /// - `self` - handler of the running system.
            /// - `E` - event payload struct type.
            pub fn cmdDestroyEvents(self: *const SystemHandler, comptime E: type) EcsError!void {
                _ = self;
                validateEventType(E);
                const Store = EventStore(E);
                if (!Store.registered) {
                    return;
                }
                Store.queueDestroyAll();
            }
            /// Queues one payload for a whole slice of entities in O(n):
            /// one shared validation pass, one capacity reservation, then an
            /// infallible loop. Accepts the same targets as `cmdSetEvent`,
            /// including reserved `cmdCreate` handles. An empty slice is a no-op.
            /// - `self` - handler of the running system.
            /// - `entities` - entities carrying the event.
            /// - `E` - event payload struct type. Needs no `ECS(...)` declaration.
            /// - `value` - payload stored with every event.
            pub fn cmdSetEvents(
                self: *const SystemHandler,
                entities: []const EntityReference,
                comptime E: type,
                value: E,
            ) EcsError!void {
                validateEventType(E);
                const Store = EventStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueSetMany(self.allocator, entities, value);
            }
            /// Queues one payload per entity, pairwise, in O(n). Lengths must
            /// match, otherwise the batch fails with `CountMismatch` before
            /// anything is queued. An empty pair of slices is a no-op.
            /// - `self` - handler of the running system.
            /// - `entities` - entities carrying the events.
            /// - `E` - event payload struct type. Needs no `ECS(...)` declaration.
            /// - `values` - payload per entity, same length as `entities`.
            pub fn cmdSetEventsEach(
                self: *const SystemHandler,
                entities: []const EntityReference,
                comptime E: type,
                values: []const E,
            ) EcsError!void {
                validateEventType(E);
                const Store = EventStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueSetEach(self.allocator, entities, values);
            }
            /// Queues destroys for a slice of entity references in O(n),
            /// without handles: each entry is matched by id plus generation,
            /// so stale references fail with `EventNotFound` and a repeated
            /// entry fails with `EventHasPendingCommand`. The batch is
            /// validated before anything is queued. An empty slice is a no-op.
            /// - `self` - handler of the running system.
            /// - `entities` - entity references holding the events.
            /// - `E` - event payload struct type.
            pub fn cmdDestroyEventsFor(
                self: *const SystemHandler,
                entities: []const EntityReference,
                comptime E: type,
            ) EcsError!void {
                validateEventType(E);
                const Store = EventStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueDestroyMany(self.allocator, entities);
            }
            /// Assigns buffer budgets for one event payload type, replacing
            /// any previous assignment wholesale. Grows buffers toward the
            /// budgets immediately (warmup); budgets trim back down at every
            /// frame end. Mid-frame growth past any budget is always allowed.
            /// Warmup never touches live committed data, so calling mid-frame
            /// is safe. Unset (`null`) fields grow forever.
            /// - `self` - handler of the running system.
            /// - `E` - event payload struct type.
            /// - `limits` - budgets to assign.
            pub fn setEventLimits(
                self: *const SystemHandler,
                comptime E: type,
                limits: EventLimits,
            ) EcsError!void {
                validateEventType(E);
                const Store = EventStore(E);
                try Store.ensureRegistered(self.allocator);
                if (limits.slots) |s| {
                    if (s > 0) {
                        try Store.ensureSlot(self.allocator, s - 1);
                    }
                }
                if (limits.pending) |p| {
                    try Store.pending.ensureTotalCapacity(self.allocator, p);
                }
                const col_cap: usize = limits.events_per_page orelse 0;
                if (limits.pages) |pg| {
                    const want: usize = pg;
                    try Store.committed.ensureTotalCapacity(self.allocator, want);
                    for (Store.page_pool.items) |*shell| {
                        try shell.entities.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.values.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.next.ensureTotalCapacity(self.allocator, col_cap);
                    }
                    while (Store.page_pool.items.len < want) {
                        var shell = EventPage(E){ .arch_id = 0 };
                        errdefer shell.entities.deinit(self.allocator);
                        errdefer shell.values.deinit(self.allocator);
                        errdefer shell.next.deinit(self.allocator);
                        try shell.entities.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.values.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.next.ensureTotalCapacity(self.allocator, col_cap);
                        try Store.page_pool.append(self.allocator, shell);
                    }
                } else if (limits.events_per_page) |ec| {
                    const cc: usize = ec;
                    for (Store.page_pool.items) |*shell| {
                        try shell.entities.ensureTotalCapacity(self.allocator, cc);
                        try shell.values.ensureTotalCapacity(self.allocator, cc);
                        try shell.next.ensureTotalCapacity(self.allocator, cc);
                    }
                }
                Store.limits = limits;
            }
            /// Drops every budget of one event payload type, restoring
            /// grow-only behavior. Takes effect immediately; already-sized
            /// buffers stay as they are until normal growth resumes.
            /// - `self` - handler of the running system.
            /// - `E` - event payload struct type.
            pub fn clearEventLimits(self: *const SystemHandler, comptime E: type) void {
                _ = self;
                validateEventType(E);
                EventStore(E).limits = .{};
            }
            /// Returns the budgets currently assigned to one event payload
            /// type, or all-`null` when none were assigned.
            /// - `self` - handler of the running system.
            /// - `E` - event payload struct type.
            ///
            /// Returns `EventLimits` - active budgets.
            pub fn eventLimits(self: *const SystemHandler, comptime E: type) EventLimits {
                _ = self;
                validateEventType(E);
                return EventStore(E).limits;
            }
            /// Returns every non-empty event page of the payload type: dense
            /// and sorted by archetype id. Read-only by contract, valid only
            /// until the current system returns.
            /// - `self` - handler of the running system.
            /// - `E` - event payload struct type.
            ///
            /// Returns `[]const EventPage(E)` - live committed pages.
            pub fn allEvents(self: *const SystemHandler, comptime E: type) []const EventPage(E) {
                validateEventType(E);
                _ = self;
                return EventStore(E).committed.items;
            }
            /// Returns the dense subset of event pages whose archetype holds
            /// all `include` components and none of the `exclude` components.
            /// The match reuses the `pages()` query, intersected with the
            /// committed pages in one merge pass. Read-only by contract; the
            /// slice lives in a per-query static buffer until the next
            /// `filterEvents` call for the same payload and query, exactly
            /// like `nonEmptyPages`.
            /// - `self` - handler of the running system.
            /// - `E` - event payload struct type.
            /// - `include` - component bundle that must be present.
            /// - `exclude` - component bundle that must be absent. `null` and empty
            ///   bundles are equivalent to no exclusion.
            ///
            /// Returns `[]const EventPage(E)` - matching pages, dense.
            pub fn filterEvents(
                self: *const SystemHandler,
                comptime E: type,
                comptime include: anytype,
                comptime exclude: anytype,
            ) []const EventPage(E) {
                validateEventType(E);
                _ = self;
                return EventFilter(E, include, exclude).filter();
            }
            /// Returns a pointer to the attribute stored for the referenced
            /// entity, like `getComponent` for components. Mutable: attributes
            /// are mid-term state that systems read and write in place. Sees
            /// committed data only; commands queued in the running system
            /// apply at the next flush.
            /// - `self` - handler of the running system.
            /// - `ref` - entity reference to resolve. Must be alive.
            /// - `E` - attribute payload type.
            ///
            /// Returns `*E` - pointer into the owning attribute column.
            pub fn getAttribute(
                self: *const SystemHandler,
                ref: EntityReference,
                comptime E: type,
            ) EcsError!*E {
                _ = self;
                validateEventType(E);
                if (!ref.isAlive()) {
                    return EcsError.EntityIsNotAlive;
                }
                const Store = AttributeStore(E);
                const loc = Store.findByEntity(ref) orelse return EcsError.AttributeNotFound;
                if (@sizeOf(E) == 0) {
                    return &Store.zst_slot;
                }
                const pg = &Store.committed.items[loc.page];
                const col: [*]E = @ptrCast(@alignCast(pg.values.items.ptr));
                return &col[loc.index];
            }
            /// Queues an attribute for the entity, creating it when absent and
            /// overwriting the payload when present (upsert). Applied at the
            /// next flush and visible to the following system. Like
            /// `cmdCreate`, the returned handle of a queued create can be
            /// used right away: reserved slots materialize during the same
            /// flush, so the attribute files under the live archetype and
            /// depth. Returns no handle: handles come only from
            /// `allAttributes` pages.
            /// - `self` - handler of the running system.
            /// - `ref` - entity carrying the attribute. Must be alive or
            ///   reserved by a queued create in the same system.
            /// - `E` - attribute payload struct type. Needs no `ECS(...)` declaration.
            /// - `value` - payload stored with the attribute.
            pub fn cmdSetAttribute(
                self: *const SystemHandler,
                ref: EntityReference,
                comptime E: type,
                value: E,
            ) EcsError!void {
                validateEventType(E);
                const Store = AttributeStore(E);
                try Store.ensureRegistered(self.allocator);
                try Ecs.validateSetTarget(ref);
                try Store.queueSet(self.allocator, ref, value);
            }
            /// Queues destruction of the attribute behind the handle. Handles
            /// come only from `AttributePage.handleAt`: unknown or already
            /// gone attributes fail with `AttributeNotFound`, a second
            /// destroy queued in the same system fails with
            /// `AttributeHasPendingCommand`.
            /// - `self` - handler of the running system.
            /// - `handle` - handle issued by `allAttributes` pages.
            pub fn cmdDestroyAttribute(self: *const SystemHandler, handle: anytype) EcsError!void {
                const HT = @TypeOf(handle);
                if (!@hasDecl(HT, "AttributePayload")) {
                    @compileError("cmdDestroyAttribute expects an AttributeHandle(E) from AttributePage.handleAt().");
                }
                const E = HT.AttributePayload;
                if (HT != AttributeHandle(E)) {
                    @compileError("cmdDestroyAttribute expects an AttributeHandle(E) from AttributePage.handleAt().");
                }
                validateEventType(E);
                const Store = AttributeStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueDestroy(self.allocator, handle);
            }
            /// Queues one payload for a whole slice of entities in O(n):
            /// one shared validation pass, one capacity reservation, then an
            /// infallible loop. Reserved handles are accepted, like the
            /// single command. An empty slice is a no-op.
            /// - `self` - handler of the running system.
            /// - `entities` - entities carrying the attribute.
            /// - `E` - attribute payload struct type.
            /// - `value` - payload stored with every attribute.
            pub fn cmdSetAttributes(
                self: *const SystemHandler,
                entities: []const EntityReference,
                comptime E: type,
                value: E,
            ) EcsError!void {
                validateEventType(E);
                const Store = AttributeStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueSetMany(self.allocator, entities, value);
            }
            /// Queues one payload per entity, pairwise, in O(n). Lengths must
            /// match, otherwise the batch fails with `CountMismatch` before
            /// anything is queued. An empty pair of slices is a no-op.
            /// - `self` - handler of the running system.
            /// - `entities` - entities carrying the attributes.
            /// - `E` - attribute payload struct type.
            /// - `values` - payload per entity, same length as `entities`.
            pub fn cmdSetAttributesEach(
                self: *const SystemHandler,
                entities: []const EntityReference,
                comptime E: type,
                values: []const E,
            ) EcsError!void {
                validateEventType(E);
                const Store = AttributeStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueSetEach(self.allocator, entities, values);
            }
            /// Queues destroys for a slice of entity references in O(n),
            /// without handles: each entry is matched by id plus generation,
            /// so stale references fail with `AttributeNotFound` and a
            /// repeated entry fails with `AttributeHasPendingCommand`. The
            /// batch is validated before anything is queued. An empty slice
            /// is a no-op.
            /// - `self` - handler of the running system.
            /// - `entities` - entity references holding the attributes.
            /// - `E` - attribute payload struct type.
            pub fn cmdDestroyAttributesFor(
                self: *const SystemHandler,
                entities: []const EntityReference,
                comptime E: type,
            ) EcsError!void {
                validateEventType(E);
                const Store = AttributeStore(E);
                try Store.ensureRegistered(self.allocator);
                try Store.queueDestroyMany(self.allocator, entities);
            }
            /// Queues destruction of every attribute of the payload type in
            /// O(1): arms a bulk wipe that the flush applies in O(pages).
            /// No-op when nothing was ever queued for the payload.
            /// - `self` - handler of the running system.
            /// - `E` - attribute payload struct type.
            pub fn cmdDestroyAttributes(self: *const SystemHandler, comptime E: type) EcsError!void {
                _ = self;
                validateEventType(E);
                const Store = AttributeStore(E);
                if (!Store.registered) {
                    return;
                }
                Store.queueDestroyAll();
            }
            /// Returns every non-empty attribute page of the payload type:
            /// dense and sorted by archetype id. Read-only by contract, valid
            /// only until the current system returns. Unlike events, pages
            /// persist across frames until destroyed.
            /// - `self` - handler of the running system.
            /// - `E` - attribute payload struct type.
            ///
            /// Returns `[]const AttributePage(E)` - live committed pages.
            pub fn allAttributes(self: *const SystemHandler, comptime E: type) []const AttributePage(E) {
                validateEventType(E);
                _ = self;
                return AttributeStore(E).committed.items;
            }
            /// Returns the dense subset of attribute pages whose archetype
            /// holds all `include` components and none of the `exclude`
            /// components. Same merge pass and buffer lifetime as
            /// `filterEvents`.
            /// - `self` - handler of the running system.
            /// - `E` - attribute payload struct type.
            /// - `include` - component bundle that must be present.
            /// - `exclude` - component bundle that must be absent. `null` and empty
            ///   bundles are equivalent to no exclusion.
            ///
            /// Returns `[]const AttributePage(E)` - matching pages, dense.
            pub fn filterAttributes(
                self: *const SystemHandler,
                comptime E: type,
                comptime include: anytype,
                comptime exclude: anytype,
            ) []const AttributePage(E) {
                validateEventType(E);
                _ = self;
                return AttributeFilter(E, include, exclude).filter();
            }
            /// Assigns buffer budgets for one attribute payload type. Same
            /// shape and replace-semantics as event limits; trims apply at
            /// frame end via the attribute trim pass.
            /// - `self` - handler of the running system.
            /// - `E` - attribute payload struct type.
            /// - `limits` - budgets to assign.
            pub fn setAttributeLimits(
                self: *const SystemHandler,
                comptime E: type,
                limits: EventLimits,
            ) EcsError!void {
                validateEventType(E);
                const Store = AttributeStore(E);
                try Store.ensureRegistered(self.allocator);
                if (limits.slots) |s| {
                    if (s > 0) {
                        try Store.ensureSlot(self.allocator, s - 1);
                    }
                }
                if (limits.pending) |p| {
                    try Store.pending.ensureTotalCapacity(self.allocator, p);
                }
                const col_cap: usize = limits.events_per_page orelse 0;
                if (limits.pages) |pg| {
                    const want: usize = pg;
                    try Store.committed.ensureTotalCapacity(self.allocator, want);
                    for (Store.page_pool.items) |*shell| {
                        try shell.entities.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.values.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.depth_zones.ensureTotalCapacity(self.allocator, col_cap);
                    }
                    while (Store.page_pool.items.len < want) {
                        var shell = AttributePage(E){ .arch_id = 0 };
                        errdefer shell.entities.deinit(self.allocator);
                        errdefer shell.values.deinit(self.allocator);
                        errdefer shell.depth_zones.deinit(self.allocator);
                        try shell.entities.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.values.ensureTotalCapacity(self.allocator, col_cap);
                        try shell.depth_zones.ensureTotalCapacity(self.allocator, col_cap);
                        try Store.page_pool.append(self.allocator, shell);
                    }
                } else if (limits.events_per_page) |ec| {
                    const cc: usize = ec;
                    for (Store.page_pool.items) |*shell| {
                        try shell.entities.ensureTotalCapacity(self.allocator, cc);
                        try shell.values.ensureTotalCapacity(self.allocator, cc);
                        try shell.depth_zones.ensureTotalCapacity(self.allocator, cc);
                    }
                }
                Store.limits = limits;
            }
            /// Drops every budget of one attribute payload type, restoring
            /// grow-only behavior.
            /// - `self` - handler of the running system.
            /// - `E` - attribute payload struct type.
            pub fn clearAttributeLimits(self: *const SystemHandler, comptime E: type) void {
                _ = self;
                validateEventType(E);
                AttributeStore(E).limits = .{};
            }
            /// Returns the budgets currently assigned to one attribute
            /// payload type, or all-`null` when none were assigned.
            /// - `self` - handler of the running system.
            /// - `E` - attribute payload struct type.
            ///
            /// Returns `EventLimits` - active budgets.
            pub fn attributeLimits(self: *const SystemHandler, comptime E: type) EventLimits {
                _ = self;
                validateEventType(E);
                return AttributeStore(E).limits;
            }
        };
        /// Deferred structural change, applied between systems in FIFO order.
        const Command = union(enum) {
            /// Create an entity; the slot was reserved at queue time and
            /// `bytes` holds packed component values in column order.
            create: struct {
                arch: u32,
                bytes: []u8,
                reserved: EntityReference,
                from_free: bool,
            },
            /// Create many entities in one pass; slots were reserved at queue
            /// time and the depth zones are consolidated once after the batch.
            create_batch: struct {
                arch: u32,
                bytes: []u8,
                reserved: []EntityReference,
                from_free: []bool,
            },
            /// Create an entity and attach it to `parent` in the same flush.
            create_child: struct {
                arch: u32,
                bytes: []u8,
                parent: EntityReference,
                reserved: EntityReference,
                from_free: bool,
            },
            /// Create many entities attached to `parent` in the same flush.
            create_children: struct {
                arch: u32,
                bytes: []u8,
                parent: EntityReference,
                reserved: []EntityReference,
                from_free: []bool,
            },
            /// Destroy an entity and its whole subtree; skipped when stale.
            destroy: EntityReference,
            /// Migrate an entity; skipped when the reference is stale.
            migrate: struct {
                ref: EntityReference,
                dest: u32,
                copy: bool,
            },
            /// Destroy every entity in one exact archetype (with subtrees).
            destroy_page: u32,
            /// Reparent an entity; `parent` is null when detaching. The
            /// parent reference carries its queue-time generation, so flush
            /// can detect a parent destroyed earlier in the same batch.
            reparent: struct {
                ref: EntityReference,
                parent: ?EntityReference,
            },
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
        /// Fills one row of an archetype with packed component values.
        /// Byte-level access through the column registry: one plain runtime
        /// loop, no unrolling over archetypes. Blob layout matches column
        /// order (see `packValues`).
        /// - `arch` - archetype id owning the row.
        /// - `row` - row position to fill.
        /// - `bytes` - packed values, one element per column.
        fn fillRowBytes(arch: u32, row: u32, bytes: []const u8) void {
            const s = &Ecs.storages[arch];
            var off: usize = 0;
            for (s.cols()) |*col| {
                const es = col.elem_size;
                if (es == 0) {
                    continue;
                }
                @memcpy(col.bytes.ptr[row * es ..][0..es], bytes[off..][0..es]);
                off += es;
            }
        }
        /// Applies every queued command in FIFO order, then clears the queue.
        /// Queue-time validation (`requireIdle`) already rejected duplicates,
        /// so flush only keeps a defensive `isAlive` guard. Immediate
        /// `destroy`/`migrateById` clear the pending flag they resolve.
        /// Reserved create slots are initialized here: rows, components and
        /// hierarchy links appear only when the command flushes.
        /// Private: runs automatically between systems; never call it directly,
        /// or pages held by user code may dangle after reallocation.
        /// - `allocator` - allocator that funded the queue and the changes.
        fn flushCommands(allocator: std.mem.Allocator) EcsError!void {
            @setEvalBranchQuota(10_000_000);
            defer Ecs.commands.clearRetainingCapacity();
            // Events flush first: sets file under the pre-command archetype,
            // then entity migrates relocate them and destroys purge them.
            try Ecs.flushEventPending(allocator);
            for (Ecs.commands.items) |cmd| {
                switch (cmd) {
                    .create => |c| {
                        errdefer allocator.free(c.bytes);
                        const row = try Ecs.initReservedSlot(allocator, c.reserved, c.arch, 0);
                        Ecs.fillRowBytes(c.arch, row, c.bytes);
                        allocator.free(c.bytes);
                    },
                    .create_batch => |c| {
                        errdefer allocator.free(c.bytes);
                        const row_start = try Ecs.initReservedBatch(allocator, c.arch, c.reserved);
                        for (c.reserved, 0..) |_, j| {
                            Ecs.fillRowBytes(c.arch, row_start + @as(u32, @intCast(j)), c.bytes);
                        }
                        // Rebuild the depth zones once. Rows are still in
                        // append order here; consolidation moves them after.
                        try Ecs.storages[c.arch].consolidateZones(
                            allocator,
                            &Ecs.zone_scratch_perm,
                            &Ecs.zone_scratch_visited,
                        );
                        allocator.free(c.bytes);
                        allocator.free(c.reserved);
                        allocator.free(c.from_free);
                    },
                    .create_child => |c| {
                        errdefer allocator.free(c.bytes);
                        // The parent must be alive when the command applies:
                        // either a real entity, or a reserved slot whose own
                        // create command already ran (FIFO order). A parent
                        // destroyed by an earlier command aborts the batch.
                        if (!c.parent.isAlive()) {
                            return EcsError.EntityIsNotAlive;
                        }
                        const child_depth = Ecs.entity_depth.items[c.parent.id] + 1;
                        const row = try Ecs.initReservedSlot(allocator, c.reserved, c.arch, child_depth);
                        Ecs.fillRowBytes(c.arch, row, c.bytes);
                        Ecs.linkChild(c.reserved.id, c.parent.id);
                        allocator.free(c.bytes);
                    },
                    .create_children => |c| {
                        errdefer allocator.free(c.bytes);
                        if (!c.parent.isAlive()) {
                            return EcsError.EntityIsNotAlive;
                        }
                        const child_depth = Ecs.entity_depth.items[c.parent.id] + 1;
                        for (c.reserved) |ref| {
                            Ecs.entity_depth.items[ref.id] = child_depth;
                            Ecs.linkChild(ref.id, c.parent.id);
                        }
                        const row_start = try Ecs.initReservedBatch(allocator, c.arch, c.reserved);
                        for (c.reserved, 0..) |_, j| {
                            Ecs.fillRowBytes(c.arch, row_start + @as(u32, @intCast(j)), c.bytes);
                        }
                        try Ecs.storages[c.arch].consolidateZones(
                            allocator,
                            &Ecs.zone_scratch_perm,
                            &Ecs.zone_scratch_visited,
                        );
                        allocator.free(c.bytes);
                        allocator.free(c.reserved);
                        allocator.free(c.from_free);
                    },
                    .destroy => |ref| {
                        if (ref.isAlive()) {
                            try ref.destroy(allocator);
                        } else if (Ecs.entity_generation.items[ref.id] == ref.gen) {
                            Ecs.clearPending(ref.id);
                        }
                    },
                    .migrate => |m| {
                        if (m.ref.isAlive()) {
                            _ = try m.ref.migrateById(allocator, m.dest, m.copy);
                            // Attribute sets queued earlier in this system
                            // still carry the old generation: rebase them so
                            // the attribute flush below files under the live
                            // archetype instead of dropping them as stale.
                            Ecs.rebaseAttributePending(m.ref.id, m.ref.gen, Ecs.entity_generation.items[m.ref.id]);
                        } else if (Ecs.entity_generation.items[m.ref.id] == m.ref.gen) {
                            Ecs.clearPending(m.ref.id);
                        }
                    },
                    .destroy_page => |arch| {
                        // Drain from the tail: every destroy cascades
                        // into the subtree, and swap-removal can touch
                        // rows of this very archetype, so a forward
                        // `for` over refs would skip survivors. Taking
                        // the last row every time re-reads the live
                        // length and terminates exactly at empty.
                        while (Ecs.storages[arch].refs.items.len > 0) {
                            const ref = Ecs.storages[arch].refs.items[Ecs.storages[arch].refs.items.len - 1];
                            try ref.destroy(allocator);
                        }
                    },
                    .reparent => |r| {
                        if (r.ref.isAlive()) {
                            // A parent destroyed by an earlier command of this
                            // batch is silently skipped, mirroring the stale
                            // reference semantics of destroy/migrate.
                            if (r.parent) |p| {
                                if (p.isAlive()) {
                                    try r.ref.reparentById(allocator, p.id);
                                }
                            } else {
                                try r.ref.reparentById(allocator, NO_ENTITY);
                            }
                            Ecs.entity_pending_parent.items[r.ref.id] = NO_ENTITY;
                            Ecs.setEntityState(r.ref.id, .{});
                        } else if (Ecs.entity_generation.items[r.ref.id] == r.ref.gen) {
                            Ecs.entity_pending_parent.items[r.ref.id] = NO_ENTITY;
                            Ecs.clearPending(r.ref.id);
                        }
                    },
                }
            }
            // Attributes flush after the entity commands: reserved slots are
            // materialized by now, so sets file under the live archetype and
            // depth (including reserved children). Migrates/destroys queued
            // in the same system already applied; the set path resolves
            // against live state below.
            try Ecs.flushAttributePending(allocator);
        }
        /// Drops every queued command without applying it, freeing create
        /// blobs, releasing the pending flags set at queue time and rolling
        /// back reserved create slots. Used when a system fails and on
        /// teardown. No flush has run, so clearing by slot id is safe.
        /// Commands are walked in reverse because fresh reservations were
        /// appended in queue order: releasing in reverse pops the appended
        /// slot arrays back to their original length, while recycled ids just
        /// return to the free list.
        /// - `allocator` - allocator that funded the queue.
        fn discardCommands(allocator: std.mem.Allocator) void {
            @setEvalBranchQuota(10_000_000);
            // Event pendings of the failing system are dropped; committed
            // events of earlier systems stay untouched. Same for attributes.
            Ecs.discardEventPending();
            Ecs.discardAttributePending();
            var i: usize = Ecs.commands.items.len;
            while (i > 0) {
                i -= 1;
                switch (Ecs.commands.items[i]) {
                    .create => |c| {
                        allocator.free(c.bytes);
                        Ecs.releaseReservation(allocator, .{
                            .ref = c.reserved,
                            .from_free = c.from_free,
                        }) catch {};
                    },
                    .create_batch => |c| {
                        allocator.free(c.bytes);
                        var j: usize = c.reserved.len;
                        while (j > 0) {
                            j -= 1;
                            Ecs.releaseReservation(allocator, .{
                                .ref = c.reserved[j],
                                .from_free = c.from_free[j],
                            }) catch {};
                        }
                        allocator.free(c.reserved);
                        allocator.free(c.from_free);
                    },
                    .create_child => |c| {
                        allocator.free(c.bytes);
                        Ecs.releaseReservation(allocator, .{
                            .ref = c.reserved,
                            .from_free = c.from_free,
                        }) catch {};
                    },
                    .create_children => |c| {
                        allocator.free(c.bytes);
                        var j: usize = c.reserved.len;
                        while (j > 0) {
                            j -= 1;
                            Ecs.releaseReservation(allocator, .{
                                .ref = c.reserved[j],
                                .from_free = c.from_free[j],
                            }) catch {};
                        }
                        allocator.free(c.reserved);
                        allocator.free(c.from_free);
                    },
                    .destroy => |ref| Ecs.clearPending(ref.id),
                    .migrate => |m| Ecs.clearPending(m.ref.id),
                    .reparent => |r| {
                        Ecs.clearPending(r.ref.id);
                        if (r.ref.id < Ecs.entityStateLen()) {
                            Ecs.entity_pending_parent.items[r.ref.id] = NO_ENTITY;
                        }
                    },
                    .destroy_page => |arch| {
                        for (Ecs.storages[arch].refs.items) |ref| {
                            Ecs.clearPending(ref.id);
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
                /// Committed events live until the whole frame ends and are
                /// cleared automatically after the last system. Events (user
                /// and lifecycle alike) filed by the last system are therefore
                /// cleared unseen: order producers before consumers.
                /// - `allocator` - funds the command queue and flushed changes.
                pub fn run(allocator: std.mem.Allocator) anyerror!void {
                    var handler = Ecs.SystemHandler{ .allocator = allocator };
                    errdefer Ecs.discardCommands(allocator);
                    inline for (order) |sys| {
                        try sys(&handler);
                        try Ecs.flushCommands(allocator);
                    }
                    try Ecs.clearAllEvents(allocator);
                    // Attributes persist; only their assigned budgets trim here.
                    try Ecs.trimAttributes(allocator);
                }
            };
        }
        /// Releases every storage and entity list owned by the namespace,
        /// then resets all runtime state so the ECS can be reused or safely
        /// deinitialized again.
        /// - `allocator` - allocator that funded all storage.
        pub fn deinit(allocator: std.mem.Allocator) void {
            @setEvalBranchQuota(10_000_000);
            for (&Ecs.storages) |*s| {
                s.deinit(allocator);
            }
            @memset(Ecs.archetype_nonempty_bits[0..], 0);
            Ecs.discardCommands(allocator);
            Ecs.commands.deinit(allocator);
            Ecs.commands = .empty;
            for (Ecs.event_registry.items) |entry| {
                entry.deinitStore(allocator);
                entry.resetRegistered();
            }
            Ecs.event_registry.deinit(allocator);
            Ecs.event_registry = .empty;
            for (Ecs.attribute_registry.items) |entry| {
                entry.deinitStore(allocator);
                entry.resetRegistered();
            }
            Ecs.attribute_registry.deinit(allocator);
            Ecs.attribute_registry = .empty;
            Ecs.entity_generation.deinit(allocator);
            Ecs.entity_generation = .empty;
            Ecs.entity_archetype.deinit(allocator);
            Ecs.entity_archetype = .empty;
            Ecs.entity_row.deinit(allocator);
            Ecs.entity_row = .empty;
            Ecs.entity_states.deinit(allocator);
            Ecs.entity_states = .empty;
            Ecs.entity_parent.deinit(allocator);
            Ecs.entity_parent = .empty;
            Ecs.entity_first_child.deinit(allocator);
            Ecs.entity_first_child = .empty;
            Ecs.entity_last_child.deinit(allocator);
            Ecs.entity_last_child = .empty;
            Ecs.entity_next_sibling.deinit(allocator);
            Ecs.entity_next_sibling = .empty;
            Ecs.entity_prev_sibling.deinit(allocator);
            Ecs.entity_prev_sibling = .empty;
            Ecs.entity_depth.deinit(allocator);
            Ecs.entity_depth = .empty;
            Ecs.entity_pending_parent.deinit(allocator);
            Ecs.entity_pending_parent = .empty;
            Ecs.zone_scratch_perm.deinit(allocator);
            Ecs.zone_scratch_perm = .empty;
            Ecs.zone_scratch_visited.deinit(allocator);
            Ecs.zone_scratch_visited = .empty;
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
    try std.testing.expect(created.state().isIdle());
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
    try std.testing.expect(recycled.state().isIdle());
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
    try std.testing.expect(migrated.state().isIdle());
    try std.testing.expect(!created.isAlive());
    try std.testing.expect(try migrated.archetypeOf() == Ecs.archetypeId(&[_]type{ Pos, Health }));
    try std.testing.expect(Ecs.count(&[_]type{ Pos, Vel }) == 0);
    try std.testing.expect(Ecs.count(&[_]type{ Pos, Health }) == 1);
    const dest_data = Ecs.storage(&[_]type{ Pos, Health });
    const moved: *const Pos = try dest_data.get(Pos, 0);
    try std.testing.expect(moved.horizontal_coordinate == 7);
}
test "component archetype lists are precomputed" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const small_id = Ecs.archetypeId(&[_]type{Pos});
    const big_id = Ecs.archetypeId(&[_]type{ Pos, Vel });
    const pos_id = Ecs.componentId(Pos);
    const vel_id = Ecs.componentId(Vel);
    try std.testing.expect(Ecs.components[pos_id].archetype_ids.len == 2);
    try std.testing.expect(Ecs.components[vel_id].archetype_ids.len == 1);
    // Inverted index rows are ascending in archetype id.
    try std.testing.expect(Ecs.components[pos_id].archetype_ids[0] == @min(small_id, big_id));
    try std.testing.expect(Ecs.components[pos_id].archetype_ids[1] == @max(small_id, big_id));
    try std.testing.expect(Ecs.components[vel_id].archetype_ids[0] == big_id);
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
test "handler pages match include sets and honor exclude" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel }, .{ Pos, Vel, Health } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };

    var all_count: usize = 0;
    for (handler.pages(&[_]type{ Pos, Vel }, null).allPages()) |page| {
        all_count += 1;
        _ = page.get(Pos);
        _ = page.entities();
    }
    try std.testing.expect(all_count == 2);

    var filtered_count: usize = 0;
    for (handler.pages(&[_]type{Pos}, &[_]type{Vel}).allPages()) |page| {
        filtered_count += 1;
        try std.testing.expect(page.archetypeInfo().component_ids.len == 1);
    }
    try std.testing.expect(filtered_count == 1);

    var null_count: usize = 0;
    for (handler.pages(&[_]type{Pos}, null).allPages()) |_| {
        null_count += 1;
    }
    try std.testing.expect(null_count == 3);

    var empty_count: usize = 0;
    for (handler.pages(&[_]type{Pos}, &[_]type{}).allPages()) |_| {
        empty_count += 1;
    }
    try std.testing.expect(empty_count == 3);

    try std.testing.expect(handler.count(&[_]type{Pos}, null) == 0);
}
test "seeded matching returns exact ascending id sets" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel }, .{ Pos, Health }, .{ Pos, Vel, Health } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    const p = Ecs.archetypeId(&[_]type{Pos});
    const pv = Ecs.archetypeId(&[_]type{ Pos, Vel });
    const ph = Ecs.archetypeId(&[_]type{ Pos, Health });
    const pvh = Ecs.archetypeId(&[_]type{ Pos, Vel, Health });

    const both = handler.pages(&[_]type{ Pos, Vel }, null).allPages();
    try std.testing.expect(both.len == 2);
    try std.testing.expect(both[0].arch_id == @min(pv, pvh));
    try std.testing.expect(both[1].arch_id == @max(pv, pvh));

    const cross = handler.pages(&[_]type{ Vel, Health }, null).allPages();
    try std.testing.expect(cross.len == 1);
    try std.testing.expect(cross[0].arch_id == pvh);

    const no_vel = handler.pages(&[_]type{Pos}, &[_]type{Vel}).allPages();
    try std.testing.expect(no_vel.len == 2);
    try std.testing.expect(no_vel[0].arch_id == @min(p, ph));
    try std.testing.expect(no_vel[1].arch_id == @max(p, ph));

    const all = handler.pages(&[_]type{Pos}, null).allPages();
    try std.testing.expect(all.len == 4);
    for (all, 0..) |page, i| {
        if (i > 0) {
            try std.testing.expect(all[i - 1].arch_id < page.arch_id);
        }
    }
}
test "page get returns mutable column and mutates data" {
    const Ecs = ECS(.{.{ Pos, Vel }});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    _ = created;
    const handler = Ecs.SystemHandler{ .allocator = allocator };

    var found_page: bool = false;
    for (handler.pages(&[_]type{ Pos, Vel }, null).nonEmptyPages()) |page| {
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
    var matched: usize = 0;
    for (handler.pages(Transform, null).allPages()) |_| {
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
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 2,
            }});
        }
        fn check_and_spawn(h: *Ecs.SystemHandler) anyerror!void {
            // Spawned by the previous system, flushed before this one.
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 4,
            }});
            // Queued, not yet visible.
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 2);
            var sum: i32 = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
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
            _ = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 9, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn move_and_kill(h: *Ecs.SystemHandler) anyerror!void {
            var target: ?Ecs.EntityReference = null;
            for (h.pages(&[_]type{ Pos, Vel }, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    if (target == null) {
                        target = ref;
                    }
                }
            }
            const ref = target.?;
            try h.cmdMigrate(ref, &[_]type{Pos}, true);
            try std.testing.expect(ref.state().pending_migrate);
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
            var found = false;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.get(Pos)) |*pos| {
                    try std.testing.expect(pos.horizontal_coordinate == 9);
                    found = true;
                }
                for (page.entities()) |ref| {
                    try std.testing.expect(ref.state().isIdle());
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
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 1,
            }});
        }
        fn queue_then_fail(h: *Ecs.SystemHandler) anyerror!void {
            var target: ?Ecs.EntityReference = null;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    target = ref;
                }
            }
            try h.cmdDestroy(target.?);
            try std.testing.expect(target.?.state().pending_destroy);
            return CustomError.Boom;
        }
        fn retry_destroy(h: *Ecs.SystemHandler) anyerror!void {
            // Discard above must have reset the flag, so queueing works again.
            var target: ?Ecs.EntityReference = null;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
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
test "entity states are one flag-packed byte per slot" {
    const Ecs = ECS(.{.{Pos}});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    var refs: [5]Ecs.EntityReference = undefined;
    for (0..5) |i| {
        refs[i] = try Ecs.create(allocator, &[_]type{Pos});
    }
    // One packed struct per slot; every slot starts idle.
    try std.testing.expect(Ecs.entity_states.items.len == 5);
    for (refs) |ref| {
        try std.testing.expect(ref.state().isIdle());
    }
    // Flags are independent: setting one kind must not affect the others.
    Ecs.setEntityState(refs[1].id, .{ .pending_destroy = true });
    Ecs.setEntityState(refs[2].id, .{ .pending_migrate = true });
    try std.testing.expect(Ecs.getEntityState(refs[0].id).isIdle());
    try std.testing.expect(Ecs.getEntityState(refs[1].id).pending_destroy);
    try std.testing.expect(!Ecs.getEntityState(refs[1].id).pending_migrate);
    try std.testing.expect(Ecs.getEntityState(refs[2].id).pending_migrate);
    try std.testing.expect(Ecs.getEntityState(refs[3].id).isIdle());
    try std.testing.expect(Ecs.getEntityState(refs[4].id).isIdle());
    try std.testing.expect(refs[1].state().pending_destroy);
    Ecs.clearPending(refs[1].id);
    Ecs.clearPending(refs[2].id);
    try std.testing.expect(refs[1].state().isIdle());
    try std.testing.expect(refs[2].state().isIdle());
}
test "bulk commands create and destroy pages" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const S = struct {
        fn spawn_many(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 6,
            }}, 3);
            _ = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
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
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 1,
            }});
        }
        fn failing(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
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
test "nonempty bits track create and destroy" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    const small = Ecs.archetypeId(&[_]type{Pos});
    const big = Ecs.archetypeId(&[_]type{ Pos, Vel });

    try std.testing.expect(!Ecs.isArchetypeNonEmpty(small));
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 0);
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).allPages().len == 2);

    const a = try Ecs.create(allocator, &[_]type{Pos});
    try std.testing.expect(Ecs.isArchetypeNonEmpty(small));
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(big));
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 1);

    const b = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    try std.testing.expect(Ecs.isArchetypeNonEmpty(big));
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 2);
    try std.testing.expect(handler.pages(&[_]type{Pos}, &[_]type{Vel}).nonEmptyPages().len == 1);

    try a.destroy(allocator);
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(small));
    try std.testing.expect(handler.pages(&[_]type{Pos}, &[_]type{Vel}).nonEmptyPages().len == 0);
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 1);

    try b.destroy(allocator);
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(big));
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 0);
    // allPages still lists every match, even when empty.
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).allPages().len == 2);
}
test "nonempty bits track migrate and destroy_page" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    const small = Ecs.archetypeId(&[_]type{Pos});
    const big = Ecs.archetypeId(&[_]type{ Pos, Vel });

    const created = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(small));
    try std.testing.expect(Ecs.isArchetypeNonEmpty(big));

    const moved = try created.migrate(allocator, &[_]type{Pos}, true);
    try std.testing.expect(Ecs.isArchetypeNonEmpty(small));
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(big));
    // Page-level view agrees with the bitset.
    for (handler.pages(&[_]type{Pos}, null).allPages()) |p| {
        try std.testing.expect(p.isEmpty() == !Ecs.isArchetypeNonEmpty(p.arch_id));
    }

    try moved.destroy(allocator);
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(small));

    _ = try Ecs.create(allocator, &[_]type{Pos});
    _ = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 2);

    const S = struct {
        fn wipe(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroyPage(&[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{S.wipe});
    try App.run(allocator);
    try std.testing.expect(!Ecs.isArchetypeNonEmpty(small));
    try std.testing.expect(Ecs.isArchetypeNonEmpty(big));
    try std.testing.expect(handler.pages(&[_]type{Pos}, null).nonEmptyPages().len == 1);
}
/// Verifies the depth-zone invariant of one archetype: zones tile the row
/// array without gaps, are sorted by depth, every row's `entity_depth` and
/// `entity_row` match its position, and the entity set is preserved.
fn expectZonesConsistent(comptime Ecs: type, comptime bundle: anytype) !void {
    const data = Ecs.storage(bundle);
    const zones = data.depth_zones.items;
    var expected_offset: u32 = 0;
    var prev_depth: ?u32 = null;
    for (zones) |z| {
        try std.testing.expect(z.offset == expected_offset);
        if (prev_depth) |pd| {
            try std.testing.expect(z.depth > pd);
        }
        prev_depth = z.depth;
        var i: u32 = z.offset;
        while (i < z.offset + z.len) : (i += 1) {
            const ref = data.refs.items[i];
            try std.testing.expect(Ecs.entity_depth.items[ref.id] == z.depth);
            try std.testing.expect(Ecs.entity_row.items[ref.id] == i);
        }
        expected_offset += z.len;
    }
    try std.testing.expect(expected_offset == data.refs.items.len);
}
test "hierarchy roots share the depth zero zone" {
    const Ecs = ECS(.{.{ Pos, Vel }});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    var refs: [5]Ecs.EntityReference = undefined;
    for (0..5) |i| {
        refs[i] = try Ecs.create(allocator, &[_]type{ Pos, Vel });
    }
    _ = refs[0];
    const data = Ecs.storage(&[_]type{ Pos, Vel });
    try std.testing.expect(data.depth_zones.items.len == 1);
    try std.testing.expect(data.depth_zones.items[0].depth == 0);
    try std.testing.expect(data.depth_zones.items[0].len == 5);
    try expectZonesConsistent(Ecs, &[_]type{ Pos, Vel });
}
test "cmdCreateChild attaches at parent depth plus one" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var parent_ref: ?Ecs.EntityReference = null;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn capture(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.parent_ref = ref;
                }
            }
            const p = S.parent_ref.?;
            _ = try h.cmdCreateChild(p, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreateChild(p, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const p = S.parent_ref.?;
            try std.testing.expect(try p.depthOf() == 0);
            try std.testing.expect(try p.childCount() == 2);
            var child_refs: [2]Ecs.EntityReference = undefined;
            var i: usize = 0;
            var it = p.children();
            while (it.next()) |c| : (i += 1) {
                try std.testing.expect(try c.depthOf() == 1);
                child_refs[i] = c;
            }
            try std.testing.expect(i == 2);
            try std.testing.expect(child_refs[0].nextSibling().?.id == child_refs[1].id);
            try std.testing.expect(child_refs[1].prevSibling().?.id == child_refs[0].id);
            try std.testing.expect(child_refs[0].parent().?.id == p.id);
            try std.testing.expect(child_refs[0].isDescendantOf(p));
            try std.testing.expect(!p.isDescendantOf(child_refs[0]));
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                try std.testing.expect(page.depthCount() == 2);
                try std.testing.expect(page.maxDepth().? == 1);
                try std.testing.expect(page.depthZone(0).?.len == 1);
                try std.testing.expect(page.depthZone(1).?.len == 2);
                try std.testing.expect(page.depthZone(2) == null);
                const z1 = page.zone(1);
                try std.testing.expect(z1.len() == 2);
                try std.testing.expect(z1.depth() == 1);
                try std.testing.expect(z1.entities().len == 2);
                try std.testing.expect(z1.get(Pos).len == 2);
                const z0 = page.zoneAt(0);
                try std.testing.expect(z0.zone.len == 1);
            }
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.capture, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "reparent updates subtree depth and destroy cascades" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        var d: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            var refs: [2]Ecs.EntityReference = undefined;
            var i: usize = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    refs[i] = ref;
                    i += 1;
                }
            }
            S.a = refs[0];
            S.d = refs[1];
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 4,
                .vertical_coordinate = 0,
            }});
        }
        fn link(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.a.children();
            S.b = it.next().?;
            S.c = it.next().?;
            try h.cmdReparent(S.c, S.b);
        }
        fn verify_and_destroy(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(try S.a.depthOf() == 0);
            try std.testing.expect(try S.b.depthOf() == 1);
            try std.testing.expect(try S.c.depthOf() == 2);
            try std.testing.expect(S.c.parent().?.id == S.b.id);
            try std.testing.expect(S.c.isDescendantOf(S.a));
            try std.testing.expect(S.b.isDescendantOf(S.a));
            try std.testing.expect(!S.a.isDescendantOf(S.c));
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            const data = Ecs.storage(&[_]type{Pos});
            try std.testing.expect(data.depth_zones.items.len == 3);
            try std.testing.expect(data.depth_zones.items[2].depth == 2);
            // Cascade: destroying the root takes b and c down with it.
            try S.a.destroy(std.testing.allocator);
            try std.testing.expect(!S.a.isAlive());
            try std.testing.expect(!S.b.isAlive());
            try std.testing.expect(!S.c.isAlive());
            try std.testing.expect(S.d.isAlive());
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            const gen_after = Ecs.entity_generation.items[S.b.id];
            _ = gen_after;
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.link, S.verify_and_destroy });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
    // Destroyed slots were recycled into the free list; a fresh create must
    // reuse one of them with no hierarchy leftovers.
    const fresh = try Ecs.create(allocator, &[_]type{Pos});
    try std.testing.expect(try fresh.depthOf() == 0);
    try std.testing.expect(fresh.parent() == null);
    try std.testing.expect(fresh.firstChild() == null);
    try std.testing.expect(fresh.nextSibling() == null);
    try std.testing.expect(fresh.prevSibling() == null);
    try expectZonesConsistent(Ecs, &[_]type{Pos});
}
test "reparent cycle is rejected at command time" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.a = ref;
                }
            }
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn attempt(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.a.children();
            S.b = it.next().?;
            S.c = it.next().?;
            // c becomes a child of b; b under c would then be a cycle and is
            // rejected right here, even though the batch is not applied yet.
            try h.cmdReparent(S.c, S.b);
            try std.testing.expectError(
                Ecs.EcsError.HierarchyCycle,
                h.cmdReparent(S.b, S.b),
            );
            try std.testing.expectError(
                Ecs.EcsError.HierarchyCycle,
                h.cmdReparent(S.b, S.c),
            );
            try std.testing.expectError(
                Ecs.EcsError.EntityIsNotAlive,
                h.cmdReparent(S.b, Ecs.EntityReference{ .id = S.b.id, .gen = S.b.gen +% 1 }),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(try S.b.depthOf() == 1);
            try std.testing.expect(try S.c.depthOf() == 2);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.attempt, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "reparent pending rejects conflicting commands" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.a = ref;
                }
            }
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn attempt(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.a.children();
            S.b = it.next().?;
            // Detach: the queued target is NO_ENTITY, but the slot is still
            // pending, so every structural command on it is rejected.
            try h.cmdReparent(S.b, null);
            try std.testing.expect(S.b.state().pending_reparent);
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdDestroy(S.b),
            );
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdMigrate(S.b, &[_]type{Pos}, true),
            );
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdReparent(S.b, S.a),
            );
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdCreateChild(S.b, &[_]type{Pos}, .{Pos{
                    .horizontal_coordinate = 3,
                    .vertical_coordinate = 0,
                }}),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(S.b.parent() == null);
            try std.testing.expect(try S.b.depthOf() == 0);
            try std.testing.expect(try S.a.childCount() == 0);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.attempt, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "migrate keeps the entity at its depth zone" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{ Pos, Health } });
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 1, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 1, .vertical_speed = 1 },
            });
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{ Pos, Vel }, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.a = ref;
                }
            }
            _ = try h.cmdCreateChild(S.a, &[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 2, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 2, .vertical_speed = 2 },
            });
        }
        fn move(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.a.children();
            S.b = it.next().?;
            // Migrate the child to another archetype: depth must be preserved.
            try h.cmdMigrate(S.b, &[_]type{ Pos, Health }, true);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            // Migrate bumped the generation, so resolve a fresh handle.
            const fresh_b = Ecs.EntityReference{
                .id = S.b.id,
                .gen = Ecs.entity_generation.items[S.b.id],
            };
            try std.testing.expect(fresh_b.isAlive());
            try std.testing.expect(try fresh_b.depthOf() == 1);
            try std.testing.expect(fresh_b.parent().?.id == S.a.id);
            try expectZonesConsistent(Ecs, &[_]type{ Pos, Health });
            try expectZonesConsistent(Ecs, &[_]type{ Pos, Vel });
            for (h.pages(&[_]type{ Pos, Health }, null).nonEmptyPages()) |page| {
                try std.testing.expect(page.depthZone(1).?.len == 1);
            }
            for (h.pages(&[_]type{ Pos, Vel }, null).nonEmptyPages()) |page| {
                try std.testing.expect(page.depthZone(0).?.len == 1);
            }
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.move, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "descendants iterator walks the subtree pre-order" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        var d: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.a = ref;
                }
            }
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn link(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.a.children();
            S.b = it.next().?;
            S.d = it.next().?;
            _ = try h.cmdCreateChild(S.b, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 4,
                .vertical_coordinate = 0,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            var it = S.a.descendants();
            S.c = it.next().?;
            // Pre-order: b, then b's child, then d.
            try std.testing.expect(S.c.id == S.b.id);
            const grand = it.next().?;
            try std.testing.expect(try grand.depthOf() == 2);
            const last = it.next().?;
            try std.testing.expect(last.id == S.d.id);
            try std.testing.expect(it.next() == null);
            // Iterating again restarts at the first descendant.
            var it2 = S.a.descendants();
            _ = it2.next().?;
            try std.testing.expect(it2.next().?.id == grand.id);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.link, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "destroy page cascades subtrees and drains safely" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.a = ref;
                }
            }
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn wipe(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroyPage(&[_]type{Pos});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 0);
            try std.testing.expect(!S.a.isAlive());
            const data = Ecs.storage(&[_]type{Pos});
            try std.testing.expect(data.refs.items.len == 0);
            try std.testing.expect(data.depth_zones.items.len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.wipe, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "bulk create consolidates zones in one pass" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.a = ref;
                }
            }
            _ = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn link(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.a.children();
            const b = it.next().?;
            _ = try h.cmdCreateChild(b, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn spawn_many(h: *Ecs.SystemHandler) anyerror!void {
            // Batch of roots lands into an archetype that already holds
            // depths 0, 1 and 2: consolidation must merge into zone 0 while
            // keeping the deeper zones intact.
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 6,
            }}, 3);
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 7,
                .vertical_coordinate = 8,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 7);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                try std.testing.expect(page.depthCount() == 3);
                try std.testing.expect(page.depthZone(0).?.len == 5);
                try std.testing.expect(page.depthZone(1).?.len == 1);
                try std.testing.expect(page.depthZone(2).?.len == 1);
                var sum: i32 = 0;
                for (page.zone(0).get(Pos)) |pos| {
                    sum += pos.horizontal_coordinate;
                }
                try std.testing.expect(sum == 23);
            }
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.link, S.spawn_many, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "reparent moves a whole tree deeper across zones" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var r1: Ecs.EntityReference = undefined;
        var r2: Ecs.EntityReference = undefined;
        var c1: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            var refs: [2]Ecs.EntityReference = undefined;
            var i: usize = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    refs[i] = ref;
                    i += 1;
                }
            }
            S.r1 = refs[0];
            S.r2 = refs[1];
            _ = try h.cmdCreateChild(S.r1, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreateChild(S.r2, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 4,
                .vertical_coordinate = 0,
            }});
        }
        fn link(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.r1.children();
            S.c1 = it.next().?;
            // Grandchild under c1, then sink the whole r2 subtree under c1:
            // r2 goes from depth 0 to 2 and its child from 1 to 3.
            _ = try h.cmdCreateChild(S.c1, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 0,
            }});
            try h.cmdReparent(S.r2, S.c1);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(try S.r1.depthOf() == 0);
            try std.testing.expect(try S.c1.depthOf() == 1);
            try std.testing.expect(try S.r2.depthOf() == 2);
            try std.testing.expect(S.r2.parent().?.id == S.c1.id);
            var it = S.r2.children();
            const d1 = it.next().?;
            try std.testing.expect(try d1.depthOf() == 3);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            const data = Ecs.storage(&[_]type{Pos});
            try std.testing.expect(data.depth_zones.items.len == 4);
            try std.testing.expect(data.depth_zones.items[0].depth == 0);
            try std.testing.expect(data.depth_zones.items[1].depth == 1);
            try std.testing.expect(data.depth_zones.items[2].depth == 2);
            try std.testing.expect(data.depth_zones.items[2].len == 2);
            try std.testing.expect(data.depth_zones.items[3].depth == 3);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.link, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "queued destroy of a cascaded child is skipped" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.r = ref;
                }
            }
            _ = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn wipe(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.r.children();
            S.c = it.next().?;
            // Destroy parent first: its cascade frees the child, so the
            // child's queued destroy must be skipped silently at flush.
            try h.cmdDestroy(S.r);
            try h.cmdDestroy(S.c);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 0);
            try std.testing.expect(!S.r.isAlive());
            try std.testing.expect(!S.c.isAlive());
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.build, S.wipe, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "failing system discards queued reparent" {
    const Ecs = ECS(.{.{Pos}});
    const CustomError = error{Boom};
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.r = ref;
                }
            }
            _ = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn queue_then_fail(h: *Ecs.SystemHandler) anyerror!void {
            var it = S.r.children();
            S.c = it.next().?;
            try h.cmdReparent(S.c, null);
            try std.testing.expect(S.c.state().pending_reparent);
            return CustomError.Boom;
        }
        fn retry_attach(h: *Ecs.SystemHandler) anyerror!void {
            // Discard above cleared the pending reparent, so the same slot
            // can be reparented again in a fresh batch.
            try h.cmdReparent(S.c, S.r);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(S.c.parent().?.id == S.r.id);
            try std.testing.expect(try S.c.depthOf() == 1);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const Failing = Ecs.Schedule(.{ S.spawn, S.build, S.queue_then_fail });
    const Recovery = Ecs.Schedule(.{ S.retry_attach, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try std.testing.expectError(CustomError.Boom, Failing.run(allocator));
    try Recovery.run(allocator);
}
test "reparent to a parent destroyed in the same batch is skipped" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var r1: Ecs.EntityReference = undefined;
        var r2: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn attempt(h: *Ecs.SystemHandler) anyerror!void {
            var refs: [2]Ecs.EntityReference = undefined;
            var i: usize = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    refs[i] = ref;
                    i += 1;
                }
            }
            S.r1 = refs[0];
            S.r2 = refs[1];
            // Destroy the target parent first, then reparent under it: the
            // parent is dead by the time the reparent applies, so the
            // reparent is skipped and r1 stays a root.
            try h.cmdDestroy(S.r2);
            try h.cmdReparent(S.r1, S.r2);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
            try std.testing.expect(S.r1.isAlive());
            try std.testing.expect(S.r1.parent() == null);
            try std.testing.expect(try S.r1.depthOf() == 0);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.attempt, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "create child under a destroy-pending parent is rejected" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn attempt(h: *Ecs.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    S.r = ref;
                }
            }
            // Destroying the parent first marks it pending, so attaching a
            // child under it in the same batch is rejected at queue time.
            // The already-queued destroy still applies afterwards.
            try h.cmdDestroy(S.r);
            try std.testing.expectError(
                Ecs.EcsError.EntityHasPendingCommand,
                h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                    .horizontal_coordinate = 2,
                    .vertical_coordinate = 0,
                }}),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 0);
            try std.testing.expect(!S.r.isAlive());
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.attempt, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdCreate returns a future handle usable as a parent" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            // Reserve and use in the same pass: the handle is not alive yet
            // but already works as a parent for a queued child.
            S.a = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            try std.testing.expect(!S.a.isAlive());
            try std.testing.expect(S.a.state().pending_create);
            try std.testing.expectError(Ecs.EcsError.EntityIsNotAlive, S.a.depthOf());
            try std.testing.expectError(Ecs.EcsError.EntityIsNotAlive, S.a.indexOf());
            S.b = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            try std.testing.expect(!S.b.isAlive());
            // A reserved handle cannot be destroyed, migrated or reparented.
            try std.testing.expectError(Ecs.EcsError.EntityIsNotAlive, h.cmdDestroy(S.a));
            try std.testing.expectError(Ecs.EcsError.EntityIsNotAlive, h.cmdMigrate(S.a, &[_]type{Pos}, true));
            try std.testing.expectError(Ecs.EcsError.EntityIsNotAlive, h.cmdReparent(S.a, null));
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(S.a.isAlive());
            try std.testing.expect(S.b.isAlive());
            try std.testing.expect(S.a.state().isIdle());
            try std.testing.expect(S.b.state().isIdle());
            try std.testing.expect(try S.a.depthOf() == 0);
            try std.testing.expect(try S.b.depthOf() == 1);
            try std.testing.expect(S.b.parent().?.id == S.a.id);
            try std.testing.expect(try S.a.childCount() == 1);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "tree is built in one pass from cmdCreate" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.a = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.b = try h.cmdCreateChild(S.a, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            S.c = try h.cmdCreateChild(S.b, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(try S.a.depthOf() == 0);
            try std.testing.expect(try S.b.depthOf() == 1);
            try std.testing.expect(try S.c.depthOf() == 2);
            try std.testing.expect(S.c.parent().?.id == S.b.id);
            try std.testing.expect(S.c.isDescendantOf(S.a));
            try std.testing.expect(try S.a.childCount() == 1);
            try std.testing.expect(try S.b.childCount() == 1);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            const data = Ecs.storage(&[_]type{Pos});
            try std.testing.expect(data.depth_zones.items.len == 3);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdCreateN returns reserved handles chainable as parents" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var refs: [3]Ecs.EntityReference = undefined;
        var child: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 6,
            }}, 3);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
                try std.testing.expect(!ref.isAlive());
                try std.testing.expect(ref.state().pending_create);
            }
            S.child = try h.cmdCreateChild(S.refs[0], &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 7,
                .vertical_coordinate = 8,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 4);
            for (S.refs) |ref| {
                try std.testing.expect(ref.isAlive());
                try std.testing.expect(try ref.depthOf() == 0);
            }
            try std.testing.expect(try S.child.depthOf() == 1);
            try std.testing.expect(S.child.parent().?.id == S.refs[0].id);
            try std.testing.expect(try S.refs[0].childCount() == 1);
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            var sum: i32 = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.get(Pos)) |pos| {
                    sum += pos.horizontal_coordinate;
                }
            }
            try std.testing.expect(sum == 22);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdCreateChildren creates a batch under a parent" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var parent: Ecs.EntityReference = undefined;
        var children: [3]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.parent = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            const created = try h.cmdCreateChildren(S.parent, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }}, 3);
            for (created, 0..) |ref, i| {
                S.children[i] = ref;
            }
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 4);
            try std.testing.expect(try S.parent.depthOf() == 0);
            try std.testing.expect(try S.parent.childCount() == 3);
            for (S.children) |ref| {
                try std.testing.expect(try ref.depthOf() == 1);
                try std.testing.expect(ref.parent().?.id == S.parent.id);
            }
            try expectZonesConsistent(Ecs, &[_]type{Pos});
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                try std.testing.expect(page.depthZone(0).?.len == 1);
                try std.testing.expect(page.depthZone(1).?.len == 3);
            }
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "discard rolls back reserved slots" {
    const Ecs = ECS(.{.{Pos}});
    const CustomError = error{Boom};
    const S = struct {
        const S = @This();
        fn spawn_then_fail(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            return CustomError.Boom;
        }
        fn retry(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
        }
    };
    const Failing = Ecs.Schedule(.{ S.spawn_then_fail });
    const Recovery = Ecs.Schedule(.{ S.retry, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try std.testing.expectError(CustomError.Boom, Failing.run(allocator));
    // Fresh reservations were rolled back: no slots, no rows left behind.
    try std.testing.expect(Ecs.count(&[_]type{Pos}) == 0);
    try std.testing.expect(Ecs.entity_generation.items.len == 0);
    try Recovery.run(allocator);
}
test "discard returns recycled reservations to the free list" {
    const Ecs = ECS(.{.{Pos}});
    const CustomError = error{Boom};
    const S = struct {
        const S = @This();
        var victim: Ecs.EntityReference = undefined;
        fn reserve_then_fail(h: *Ecs.SystemHandler) anyerror!void {
            // Reserve the recycled slot, then fail before flush.
            victim = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            return CustomError.Boom;
        }
        fn retry(h: *Ecs.SystemHandler) anyerror!void {
            const b = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            // The same recycled id must be reused after the rollback.
            try std.testing.expect(b.id == S.victim.id);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.count(&[_]type{Pos}, null) == 1);
        }
    };
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    // Put one entity into the free list, then let the failing system reserve
    // its recycled slot.
    const a = try Ecs.create(allocator, &[_]type{Pos});
    try a.destroy(allocator);
    const Failing = Ecs.Schedule(.{ S.reserve_then_fail });
    const Recovery = Ecs.Schedule(.{ S.retry, S.verify });
    try std.testing.expectError(CustomError.Boom, Failing.run(allocator));
    try Recovery.run(allocator);
}
test "events flow to the next system and clear at frame end" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 2,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 10 });
            // Queued, not yet visible.
            try std.testing.expect(h.allEvents(Damage).len == 0);
        }
        fn consume(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(!pages[0].isEmpty());
            try std.testing.expect(pages[0].entityAt(0).id == S.target.id);
            try std.testing.expect(pages[0].valueAt(0).amount == 10);
            try std.testing.expect(pages[0].entityList().len == 1);
            try std.testing.expect(pages[0].eventList()[0].amount == 10);
            try std.testing.expect(pages[0].archetypeInfo().component_ids.len == 1);
            try h.cmdDestroyEvent(pages[0].handleAt(0));
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.consume, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
    // Frame-end auto clear: nothing leaks into the next frame.
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try std.testing.expect(handler.allEvents(Damage).len == 0);
}
test "event set rewrites the queued payload" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit_twice(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 10 });
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 25 });
        }
        fn rewrite_committed(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 25);
            // Re-emitting over a committed event updates it in place.
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 40 });
        }
        fn verify_updated(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 40);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit_twice, S.rewrite_committed, S.verify_updated });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "event destroy validates handles" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        var other: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.other = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 5 });
        }
        fn destroy_twice(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            const handle = pages[0].handleAt(0);
            try h.cmdDestroyEvent(handle);
            // Second destroy in the same system: rejected at queue time.
            try std.testing.expectError(
                Ecs.EcsError.EventHasPendingCommand,
                h.cmdDestroyEvent(handle),
            );
            // Forged handle over an entity without the event.
            const forged = Ecs.EventHandle(Damage){
                .entity = S.other,
                .arch_id = pages[0].arch_id,
                .index = 0,
            };
            try std.testing.expectError(
                Ecs.EcsError.EventNotFound,
                h.cmdDestroyEvent(forged),
            );
            // Stale generation never matches a committed entry.
            const stale = Ecs.EventHandle(Damage){
                .entity = .{ .id = S.target.id, .gen = S.target.gen +% 1 },
                .arch_id = pages[0].arch_id,
                .index = 0,
            };
            try std.testing.expectError(
                Ecs.EcsError.EventNotFound,
                h.cmdDestroyEvent(stale),
            );
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.destroy_twice, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "filterEvents honors include and exclude" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var small: Ecs.EntityReference = undefined;
        var big: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.small = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.big = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 2, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            // Queue big first: committed pages must still come out sorted.
            try h.cmdSetEvent(S.big, Damage, .{ .amount = 2 });
            try h.cmdSetEvent(S.small, Damage, .{ .amount = 1 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const all = h.allEvents(Damage);
            try std.testing.expect(all.len == 2);
            try std.testing.expect(all[0].arch_id < all[1].arch_id);
            const no_vel = h.filterEvents(Damage, &[_]type{Pos}, &[_]type{Vel});
            try std.testing.expect(no_vel.len == 1);
            try std.testing.expect(no_vel[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(no_vel[0].valueAt(0).amount == 1);
            const with_vel = h.filterEvents(Damage, &[_]type{ Pos, Vel }, null);
            try std.testing.expect(with_vel.len == 1);
            try std.testing.expect(with_vel[0].arch_id == Ecs.archetypeId(&[_]type{ Pos, Vel }));
            try std.testing.expect(with_vel[0].valueAt(0).amount == 2);
            const none = h.filterEvents(Damage, &[_]type{Vel}, &[_]type{Pos});
            try std.testing.expect(none.len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "destroying an entity purges its events" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 7 });
        }
        fn kill(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 1);
            try h.cmdDestroy(S.target);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 0);
            try std.testing.expect(!S.target.isAlive());
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.kill, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "migrating an entity moves its events" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        var stale: Ecs.EventHandle(Damage) = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 7, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 1, .vertical_speed = 1 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 9 });
        }
        fn capture_and_move(h: *Ecs.SystemHandler) anyerror!void {
            S.stale = h.allEvents(Damage)[0].handleAt(0);
            try h.cmdMigrate(S.target, &[_]type{Pos}, true);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(pages[0].valueAt(0).amount == 9);
            const filtered = h.filterEvents(Damage, &[_]type{Pos}, null);
            try std.testing.expect(filtered.len == 1);
            const missing = h.filterEvents(Damage, &[_]type{Pos, Vel}, null);
            try std.testing.expect(missing.len == 0);
            // The pre-migrate handle is invalidated by the generation bump.
            try std.testing.expectError(
                Ecs.EcsError.EventNotFound,
                h.cmdDestroyEvent(S.stale),
            );
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.capture_and_move, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "failing system discards event commands" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const CustomError = error{Boom};
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 10 });
        }
        fn queue_then_fail(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 99 });
            // Pending rewrite is invisible until flush.
            try std.testing.expect(h.allEvents(Damage)[0].valueAt(0).amount == 10);
            return CustomError.Boom;
        }
        fn verify_kept(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 10);
        }
    };
    const Failing = Ecs.Schedule(.{ S.spawn, S.emit, S.queue_then_fail });
    const Recovery = Ecs.Schedule(.{S.verify_kept});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try std.testing.expectError(CustomError.Boom, Failing.run(allocator));
    try Recovery.run(allocator);
}
test "events attach to reserved handles and support marker payloads" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const Marker = struct {};
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn_and_emit(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 11 });
            try h.cmdSetEvent(S.target, Marker, .{});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(S.target.isAlive());
            const damages = h.allEvents(Damage);
            try std.testing.expect(damages.len == 1);
            try std.testing.expect(damages[0].count() == 1);
            try std.testing.expect(damages[0].valueAt(0).amount == 11);
            const markers = h.allEvents(Marker);
            try std.testing.expect(markers.len == 1);
            try std.testing.expect(markers[0].count() == 1);
            try h.cmdDestroyEvent(damages[0].handleAt(0));
            try h.cmdDestroyEvent(markers[0].handleAt(0));
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 0);
            try std.testing.expect(h.allEvents(Marker).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn_and_emit, S.verify, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdDestroyEvents wipes the whole payload" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var small: Ecs.EntityReference = undefined;
        var big: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.small = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.big = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 2, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.small, Damage, .{ .amount = 1 });
            try h.cmdSetEvent(S.big, Damage, .{ .amount = 2 });
        }
        fn wipe_all(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 2);
            // A set queued before the wipe is cancelled by it...
            try h.cmdSetEvent(S.small, Damage, .{ .amount = 99 });
            try h.cmdDestroyEvents(Damage);
            // ...a second bulk in the same system is idempotent...
            try h.cmdDestroyEvents(Damage);
            // ...while a set queued after the wipe survives.
            try h.cmdSetEvent(S.big, Damage, .{ .amount = 7 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].entityAt(0).id == S.big.id);
            try std.testing.expect(pages[0].valueAt(0).amount == 7);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.wipe_all, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
    // Bulk over a payload with nothing queued is a no-op, not an error.
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try handler.cmdDestroyEvents(Damage);
    // The wipe flag never leaks across flushes: a fresh frame flows normally.
    const Fresh = struct {
        fn verify_fresh(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            var total: usize = 0;
            for (pages) |page| {
                total += page.count();
            }
            try std.testing.expect(total == 2);
        }
    };
    try Ecs.Schedule(.{ S.emit, Fresh.verify_fresh }).run(allocator);
}
test "mass per-handle destroy keeps the index consistent" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 200;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            for (S.refs, 0..) |ref, i| {
                try h.cmdSetEvent(ref, Damage, .{ .amount = @intCast(i) });
            }
        }
        fn destroy_odd(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
            // Collect handles first: rows move under swap-remove, so live
            // indices would skip entries while handles stay valid.
            var handles: [N / 2]Ecs.EventHandle(Damage) = undefined;
            var hn: usize = 0;
            for (0..pages[0].count()) |i| {
                if (i % 2 == 1) {
                    handles[hn] = pages[0].handleAt(i);
                    hn += 1;
                }
            }
            for (handles) |handle| {
                try h.cmdDestroyEvent(handle);
            }
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N / 2);
            // Even payloads 0..198 survive regardless of row order.
            var sum: u64 = 0;
            for (pages[0].eventList()) |ev| {
                try std.testing.expect(ev.amount % 2 == 0);
                sum += ev.amount;
            }
            try std.testing.expect(sum == 9900);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.destroy_odd, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdSetEvents emits one payload for many entities" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 300;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            // Single set first: the batch overwrites it via the pending index.
            try h.cmdSetEvent(S.refs[0], Damage, .{ .amount = 1 });
            try h.cmdSetEvents(S.refs[0..], Damage, .{ .amount = 5 });
            try h.cmdSetEvents(&.{}, Damage, .{ .amount = 9 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
            var sum: u64 = 0;
            for (pages[0].eventList()) |ev| {
                try std.testing.expect(ev.amount == 5);
                sum += ev.amount;
            }
            try std.testing.expect(sum == 5 * N);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdSetEventsEach pairs entities with payloads" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 200;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        var values: [N]Damage = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
                S.values[i] = .{ .amount = @intCast(i) };
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEventsEach(S.refs[0..], Damage, S.values[0..]);
            try std.testing.expectError(
                Ecs.EcsError.CountMismatch,
                h.cmdSetEventsEach(S.refs[0..10], Damage, S.values[0..9]),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
            var sum: u64 = 0;
            for (pages[0].eventList()) |ev| {
                sum += ev.amount;
            }
            try std.testing.expect(sum == N * (N - 1) / 2);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdDestroyEventsFor validates the batch before queueing" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 200;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            var values: [N]Damage = undefined;
            for (0..N) |i| {
                values[i] = .{ .amount = @intCast(i) };
            }
            try h.cmdSetEventsEach(S.refs[0..], Damage, values[0..]);
        }
        fn errors(h: *Ecs.SystemHandler) anyerror!void {
            const forged = Ecs.EntityReference{ .id = S.refs[0].id, .gen = S.refs[0].gen +% 1 };
            try std.testing.expectError(
                Ecs.EcsError.EventNotFound,
                h.cmdDestroyEventsFor(&.{forged}, Damage),
            );
            // Mixed batch fails as a whole...
            try std.testing.expectError(
                Ecs.EcsError.EventNotFound,
                h.cmdDestroyEventsFor(&[_]Ecs.EntityReference{ S.refs[4], forged }, Damage),
            );
            // ...while a repeated batch call is a double destroy.
            try h.cmdDestroyEventsFor(S.refs[2..3], Damage);
            try std.testing.expectError(
                Ecs.EcsError.EventHasPendingCommand,
                h.cmdDestroyEventsFor(S.refs[2..3], Damage),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            // refs[2] is gone (first batch applied); refs[4] survived the
            // failed mixed batch, proving nothing was queued for it.
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N - 1);
            var found2 = false;
            var found4 = false;
            var sum: u64 = 0;
            for (pages[0].eventList()) |ev| {
                if (ev.amount == 2) {
                    found2 = true;
                }
                if (ev.amount == 4) {
                    found4 = true;
                }
                sum += ev.amount;
            }
            try std.testing.expect(!found2);
            try std.testing.expect(found4);
            try std.testing.expect(sum == N * (N - 1) / 2 - 2);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.errors, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "cmdDestroyEventsFor collapses duplicates inside one call" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var refs: [3]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, 3);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            const values = [_]Damage{ .{ .amount = 10 }, .{ .amount = 20 }, .{ .amount = 30 } };
            try h.cmdSetEventsEach(S.refs[0..], Damage, values[0..]);
        }
        fn wipe_dup(h: *Ecs.SystemHandler) anyerror!void {
            // No error: the duplicated entry collapses into one destroy.
            try h.cmdDestroyEventsFor(&[_]Ecs.EntityReference{ S.refs[0], S.refs[0] }, Damage);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 2);
            var sum: u64 = 0;
            for (pages[0].eventList()) |ev| {
                sum += ev.amount;
            }
            try std.testing.expect(sum == 50);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.wipe_dup, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "lifecycle Create is filed for every created entity" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const S = struct {
        const S = @This();
        var a: Ecs.EntityReference = undefined;
        var b: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.a = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.b = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 2, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
            // Filing happens at flush, not at queue time.
            try std.testing.expect(h.allEvents(Ecs.Create).len == 0);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Ecs.Create);
            try std.testing.expect(pages.len == 2);
            var found_a = false;
            var found_b = false;
            for (pages) |page| {
                for (page.entityList()) |e| {
                    if (e.id == S.a.id) {
                        found_a = true;
                    }
                    if (e.id == S.b.id) {
                        found_b = true;
                    }
                }
            }
            try std.testing.expect(found_a and found_b);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
    // Frame-end clear covers lifecycle payloads.
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try std.testing.expect(handler.allEvents(Ecs.Create).len == 0);
}
test "lifecycle Destroy records the archetype and survives the purge" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 1, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 5 });
        }
        fn kill(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroy(S.target);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(!S.target.isAlive());
            // The user event is purged with the entity...
            try std.testing.expect(h.allEvents(Damage).len == 0);
            // ...while the Destroy record survives it.
            const pages = h.allEvents(Ecs.Destroy);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].entityAt(0).id == S.target.id);
            try std.testing.expect(pages[0].entityAt(0).gen == S.target.gen);
            try std.testing.expect(pages[0].valueAt(0).archetype == Ecs.archetypeId(&[_]type{ Pos, Vel }));
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.kill, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "lifecycle Migrate keeps full history" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos}, .{Vel} });
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 1, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn move1(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdMigrate(S.target, &[_]type{Pos}, true);
        }
        fn move2(h: *Ecs.SystemHandler) anyerror!void {
            var live: ?Ecs.EntityReference = null;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |ref| {
                    live = ref;
                }
            }
            S.target = live.?;
            try h.cmdMigrate(S.target, &[_]type{Vel}, true);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pv = Ecs.archetypeId(&[_]type{ Pos, Vel });
            const p = Ecs.archetypeId(&[_]type{Pos});
            const v = Ecs.archetypeId(&[_]type{Vel});
            // Both records follow the entity into V: history coalesces.
            const pages = h.allEvents(Ecs.Migrate);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].arch_id == v);
            try std.testing.expect(pages[0].count() == 2);
            try std.testing.expect(pages[0].entityAt(0).isAlive());
            try std.testing.expect(pages[0].entityAt(1).isAlive());
            // Chronological: PV->P first, then P->V.
            try std.testing.expect(pages[0].valueAt(0).from == pv);
            try std.testing.expect(pages[0].valueAt(0).to == p);
            try std.testing.expect(pages[0].valueAt(1).from == p);
            try std.testing.expect(pages[0].valueAt(1).to == v);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.move1, S.move2, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "user events follow the entity across migrate" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 1, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.target, Damage, .{ .amount = 42 });
        }
        fn move(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdMigrate(S.target, &[_]type{Pos}, true);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 42);
            const e = pages[0].entityAt(0);
            try std.testing.expect(e.isAlive());
            try std.testing.expect(e.gen == S.target.gen +% 1);
            // The stale pre-migrate handle finds nothing...
            try std.testing.expectError(
                Ecs.EcsError.EventNotFound,
                h.cmdDestroyEvent(Ecs.EventHandle(Damage){
                    .entity = S.target,
                    .arch_id = pages[0].arch_id,
                    .index = 0,
                }),
            );
            // ...while the fresh handle destroys.
            try h.cmdDestroyEvent(pages[0].handleAt(0));
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.move, S.verify, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "lifecycle Reparent and DepthUpdate partition the move" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        var r2: Ecs.EntityReference = undefined;
        var r3: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        var g: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.r = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.r2 = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            S.r3 = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
            S.c = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 4,
                .vertical_coordinate = 0,
            }});
            S.g = try h.cmdCreateChild(S.c, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 0,
            }});
        }
        fn move1(h: *Ecs.SystemHandler) anyerror!void {
            // Same depth (1 -> 1): Reparent only, no DepthUpdate.
            try h.cmdReparent(S.c, S.r2);
        }
        fn move2(h: *Ecs.SystemHandler) anyerror!void {
            // The R2 subtree sinks one level.
            try h.cmdReparent(S.r2, S.r3);
        }
        fn check_and_reorder(h: *Ecs.SystemHandler) anyerror!void {
            var reps: usize = 0;
            var found_c = false;
            var found_r2 = false;
            for (h.allEvents(Ecs.Reparent)) |page| {
                reps += page.count();
                for (0..page.count()) |i| {
                    const e = page.entityAt(i);
                    const v = page.valueAt(i);
                    if (e.id == S.c.id) {
                        try std.testing.expect(v.old_parent.?.id == S.r.id);
                        try std.testing.expect(v.new_parent.?.id == S.r2.id);
                        found_c = true;
                    } else if (e.id == S.r2.id) {
                        try std.testing.expect(v.old_parent == null);
                        try std.testing.expect(v.new_parent.?.id == S.r3.id);
                        found_r2 = true;
                    } else {
                        try std.testing.expect(false);
                    }
                }
            }
            try std.testing.expect(reps == 2);
            try std.testing.expect(found_c and found_r2);
            var depths: usize = 0;
            var seen_r2 = false;
            var seen_c = false;
            var seen_g = false;
            for (h.allEvents(Ecs.DepthUpdate)) |page| {
                depths += page.count();
                for (0..page.count()) |i| {
                    const e = page.entityAt(i);
                    const v = page.valueAt(i);
                    if (e.id == S.r2.id) {
                        try std.testing.expect(v.old_depth == 0 and v.new_depth == 1);
                        seen_r2 = true;
                    } else if (e.id == S.c.id) {
                        try std.testing.expect(v.old_depth == 1 and v.new_depth == 2);
                        seen_c = true;
                    } else if (e.id == S.g.id) {
                        try std.testing.expect(v.old_depth == 2 and v.new_depth == 3);
                        seen_g = true;
                    } else {
                        try std.testing.expect(false);
                    }
                }
            }
            try std.testing.expect(depths == 3);
            try std.testing.expect(seen_r2 and seen_c and seen_g);
            // Same-parent reorder files nothing.
            try h.cmdReparent(S.c, S.r2);
        }
        fn verify_quiet(h: *Ecs.SystemHandler) anyerror!void {
            var reps: usize = 0;
            for (h.allEvents(Ecs.Reparent)) |page| {
                reps += page.count();
            }
            var depths: usize = 0;
            for (h.allEvents(Ecs.DepthUpdate)) |page| {
                depths += page.count();
            }
            try std.testing.expect(reps == 2);
            try std.testing.expect(depths == 3);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.move1, S.move2, S.check_and_reorder, S.verify_quiet });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "lifecycle history duplicates share handles as aliases" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        var r2: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.r = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.r2 = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            S.c = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
        }
        fn move1(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdReparent(S.c, S.r2);
        }
        fn move2(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdReparent(S.c, S.r);
        }
        fn wipe(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Ecs.Reparent);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 2);
            // One destroy takes both alias rows...
            try h.cmdDestroyEvent(pages[0].handleAt(1));
            // ...so the second handle is already destroy-pending.
            try std.testing.expectError(
                Ecs.EcsError.EventHasPendingCommand,
                h.cmdDestroyEvent(pages[0].handleAt(0)),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Ecs.Reparent).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.move1, S.move2, S.wipe, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "lifecycle Destroy keeps every instance across slot recycle" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        var first: Ecs.EntityReference = undefined;
        var second: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.first = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn kill1(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroy(S.first);
        }
        fn respawn(h: *Ecs.SystemHandler) anyerror!void {
            S.second = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            // The freed slot is recycled with a bumped generation.
            try std.testing.expect(S.second.id == S.first.id);
            try std.testing.expect(S.second.gen == S.first.gen +% 1);
        }
        fn mid(h: *Ecs.SystemHandler) anyerror!void {
            const creates = h.allEvents(Ecs.Create);
            try std.testing.expect(creates.len == 1);
            try std.testing.expect(creates[0].count() == 1);
            try std.testing.expect(creates[0].entityAt(0).gen == S.second.gen);
            const destroys = h.allEvents(Ecs.Destroy);
            try std.testing.expect(destroys.len == 1);
            try std.testing.expect(destroys[0].count() == 1);
            try std.testing.expect(destroys[0].entityAt(0).gen == S.first.gen);
        }
        fn kill2(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroy(S.second);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            // The second purge spared the stale first record.
            try std.testing.expect(h.allEvents(Ecs.Create).len == 0);
            const destroys = h.allEvents(Ecs.Destroy);
            try std.testing.expect(destroys.len == 1);
            try std.testing.expect(destroys[0].count() == 2);
            var found_first = false;
            var found_second = false;
            for (destroys[0].entityList()) |e| {
                if (e.gen == S.first.gen) {
                    found_first = true;
                }
                if (e.gen == S.second.gen) {
                    found_second = true;
                }
            }
            try std.testing.expect(found_first and found_second);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.kill1, S.respawn, S.mid, S.kill2, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "lifecycle events clear at frame end and survive deinit reuse" {
    const Ecs = ECS(.{.{Pos}});
    const S = struct {
        const S = @This();
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            _ = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Ecs.Create);
            var total: usize = 0;
            for (pages) |page| {
                total += page.count();
            }
            try std.testing.expect(total == 2);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify });
    const allocator = std.testing.allocator;
    try App.run(allocator);
    Ecs.deinit(allocator);
    // Reuse after deinit re-registers lifecycle payloads on first filing.
    try App.run(allocator);
    Ecs.deinit(allocator);
}
test "event limits warm up buffers on assignment" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Damage = struct { amount: u32 };
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try handler.setEventLimits(Damage, .{
        .slots = 500,
        .pending = 64,
        .events_per_page = 32,
        .pages = 2,
    });
    const got = handler.eventLimits(Damage);
    try std.testing.expectEqual(@as(?u32, 500), got.slots);
    try std.testing.expectEqual(@as(?u32, 64), got.pending);
    try std.testing.expectEqual(@as(?u32, 32), got.events_per_page);
    try std.testing.expectEqual(@as(?u32, 2), got.pages);
    const Store = Ecs.EventStore(Damage);
    try std.testing.expect(Store.rows.items.len >= 500);
    try std.testing.expect(Store.pending_rows.items.len >= 500);
    try std.testing.expect(Store.pending.capacity >= 64);
    try std.testing.expect(Store.committed.capacity >= 2);
    try std.testing.expect(Store.page_pool.items.len == 2);
    for (Store.page_pool.items) |*shell| {
        try std.testing.expect(shell.entities.capacity >= 32);
        try std.testing.expect(shell.values.capacity >= 32);
        try std.testing.expect(shell.next.capacity >= 32);
    }
    // Replace semantics: a second set overwrites wholesale.
    try handler.setEventLimits(Damage, .{ .pending = 16 });
    const got2 = handler.eventLimits(Damage);
    try std.testing.expect(got2.slots == null);
    try std.testing.expectEqual(@as(?u32, 16), got2.pending);
    // Clearing restores grow-only defaults.
    handler.clearEventLimits(Damage);
    try std.testing.expect(handler.eventLimits(Damage).pending == null);
}
test "event limits trim buffers at frame end" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 100;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        var mid_col_cap: usize = 0;
        var mid_pending_cap: usize = 0;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            var values: [N]Damage = undefined;
            for (0..N) |i| {
                values[i] = .{ .amount = @intCast(i) };
            }
            try h.cmdSetEventsEach(S.refs[0..], Damage, values[0..]);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
            var sum: u64 = 0;
            for (pages[0].eventList()) |ev| {
                sum += ev.amount;
            }
            try std.testing.expect(sum == N * (N - 1) / 2);
            const Store = Ecs.EventStore(Damage);
            S.mid_col_cap = Store.committed.items[0].entities.capacity;
            S.mid_pending_cap = Store.pending.capacity;
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try handler.setEventLimits(Damage, .{ .events_per_page = 4, .pages = 1, .pending = 8 });
    try App.run(allocator);
    try std.testing.expect(S.mid_col_cap >= N);
    try std.testing.expect(S.mid_pending_cap >= N);
    const Store = Ecs.EventStore(Damage);
    try std.testing.expect(Store.page_pool.items.len == 1);
    try std.testing.expect(Store.page_pool.items[0].entities.capacity < S.mid_col_cap);
    try std.testing.expect(Store.pending.capacity < N);
    // The next frame still computes correctly after the trim.
    try App.run(allocator);
}
test "slot limits never drop live coverage" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 50;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvents(S.refs[0..], Damage, .{ .amount = 3 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try handler.setEventLimits(Damage, .{ .slots = 5 });
    try App.run(allocator);
    const Store = Ecs.EventStore(Damage);
    try std.testing.expect(Store.rows.items.len == N);
    try std.testing.expect(Store.pending_rows.items.len == N);
    try App.run(allocator);
}
test "cleared limits restore grow-only behavior" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Damage = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var small: Ecs.EntityReference = undefined;
        var big: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.small = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.big = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 2, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvent(S.small, Damage, .{ .amount = 1 });
            try h.cmdSetEvent(S.big, Damage, .{ .amount = 2 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allEvents(Damage).len == 2);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try handler.setEventLimits(Damage, .{ .pages = 1 });
    try App.run(allocator);
    try std.testing.expect(Ecs.EventStore(Damage).page_pool.items.len == 1);
    handler.clearEventLimits(Damage);
    try std.testing.expect(handler.eventLimits(Damage).pages == null);
    try App.run(allocator);
    try std.testing.expect(Ecs.EventStore(Damage).page_pool.items.len == 2);
}
test "zero limits retain nothing" {
    const Ecs = ECS(.{.{Pos}});
    const Damage = struct { amount: u32 };
    const N: usize = 10;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetEvents(S.refs[0..], Damage, .{ .amount = 7 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allEvents(Damage);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try handler.setEventLimits(Damage, .{ .pending = 0, .events_per_page = 0, .pages = 0 });
    try App.run(allocator);
    const Store = Ecs.EventStore(Damage);
    try std.testing.expect(Store.page_pool.items.len == 0);
    try std.testing.expect(Store.pending.capacity == 0);
    try std.testing.expect(Store.committed.capacity == 0);
    // The next frame still computes correctly after full release.
    try App.run(allocator);
}
test "attributes set, get, update and destroy" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn set(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 10 });
            // Committed-only reads: invisible until flush.
            try std.testing.expectError(
                Ecs.EcsError.AttributeNotFound,
                h.getAttribute(S.target, Buff),
            );
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].entityAt(0).id == S.target.id);
            const p = try h.getAttribute(S.target, Buff);
            try std.testing.expect(p.amount == 10);
            // Mutable in place, then overwritten by upsert.
            p.amount = 25;
            try std.testing.expect((try h.getAttribute(S.target, Buff)).amount == 25);
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 40 });
        }
        fn verify_updated(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 40);
            const handle = pages[0].handleAt(0);
            try h.cmdDestroyAttribute(handle);
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allAttributes(Buff).len == 0);
            try std.testing.expectError(
                Ecs.EcsError.AttributeNotFound,
                h.getAttribute(S.target, Buff),
            );
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.set, S.verify, S.verify_updated, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attributes validate handles and accept reserved slots" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        var other: Ecs.EntityReference = undefined;
        fn spawn_and_reserve(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            const reserved = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            // Like events, reserved handles are accepted: the slot
            // materializes during the same flush, so the attribute files
            // under the live archetype and depth.
            try h.cmdSetAttribute(reserved, Buff, .{ .amount = 1 });
            S.other = reserved;
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(S.other.isAlive());
            // The reserved set from the previous system is visible now.
            try std.testing.expect((try h.getAttribute(S.other, Buff)).amount == 1);
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 5 });
            try h.cmdSetAttribute(S.other, Buff, .{ .amount = 6 });
        }
        fn destroy_twice(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 2);
            const handle = pages[0].handleAt(0);
            try h.cmdDestroyAttribute(handle);
            try std.testing.expectError(
                Ecs.EcsError.AttributeHasPendingCommand,
                h.cmdDestroyAttribute(handle),
            );
            const forged = Ecs.AttributeHandle(Buff){
                .entity = .{ .id = S.target.id, .gen = S.target.gen +% 1 },
                .arch_id = pages[0].arch_id,
                .index = 0,
            };
            try std.testing.expectError(
                Ecs.EcsError.AttributeNotFound,
                h.cmdDestroyAttribute(forged),
            );
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            // One of the two attributes was destroyed.
            var total: usize = 0;
            for (h.allAttributes(Buff)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == 1);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn_and_reserve, S.emit, S.destroy_twice, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attributes on reserved children land in the right depth zone" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var parent: Ecs.EntityReference = undefined;
        var child: Ecs.EntityReference = undefined;
        var grandchild: Ecs.EntityReference = undefined;
        fn build(h: *Ecs.SystemHandler) anyerror!void {
            S.parent = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 0,
                .vertical_coordinate = 0,
            }});
            S.child = try h.cmdCreateChild(S.parent, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.grandchild = try h.cmdCreateChild(S.child, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            // Reserved handles work like events: the slots materialize
            // during the same flush, filed under live depth.
            try h.cmdSetAttribute(S.child, Buff, .{ .amount = 10 });
            try h.cmdSetAttribute(S.grandchild, Buff, .{ .amount = 20 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 2);
            try std.testing.expect(pages[0].depthZone(0) == null);
            const z1 = pages[0].depthZone(1).?;
            try std.testing.expect(z1.len == 1);
            try std.testing.expect((try h.getAttribute(S.child, Buff)).amount == 10);
            const z2 = pages[0].depthZone(2).?;
            try std.testing.expect(z2.len == 1);
            try std.testing.expect((try h.getAttribute(S.grandchild, Buff)).amount == 20);
            try std.testing.expect(try S.child.depthOf() == 1);
            try std.testing.expect(try S.grandchild.depthOf() == 2);
        }
    };
    const App = Ecs.Schedule(.{ S.build, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attribute set survives same-system migrate" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 1, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 1 });
        }
        fn set_and_move(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 2 });
            try h.cmdMigrate(S.target, &[_]type{Pos}, true);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            // Filed under the live (destination) archetype, not dropped.
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 2);
            const live = pages[0].entityAt(0);
            try std.testing.expect(live.isAlive());
            try std.testing.expect(live.gen == S.target.gen +% 1);
            try std.testing.expect((try h.getAttribute(live, Buff)).amount == 2);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.set_and_move, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attribute set with same-system destroy is dropped" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 1 });
        }
        fn set_and_kill(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 2 });
            try h.cmdDestroy(S.target);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(!S.target.isAlive());
            try std.testing.expect(h.allAttributes(Buff).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.set_and_kill, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attributes persist across frames" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 11 });
        }
        fn read1(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect((try h.getAttribute(S.target, Buff)).amount == 11);
        }
        fn read2(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 11);
        }
        fn read3(h: *Ecs.SystemHandler) anyerror!void {
            // Mutations persist too.
            (try h.getAttribute(S.target, Buff)).amount = 12;
            try std.testing.expect((try h.getAttribute(S.target, Buff)).amount == 12);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.read1, S.read2, S.read3 });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
    // Still there after the frame: no auto-clear.
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    try std.testing.expect(handler.allAttributes(Buff).len == 1);
}
test "attributes filter by archetype" {
    const Ecs = ECS(.{ .{Pos}, .{ Pos, Vel } });
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var small: Ecs.EntityReference = undefined;
        var big: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.small = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.big = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 2, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.big, Buff, .{ .amount = 2 });
            try h.cmdSetAttribute(S.small, Buff, .{ .amount = 1 });
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const all = h.allAttributes(Buff);
            try std.testing.expect(all.len == 2);
            try std.testing.expect(all[0].arch_id < all[1].arch_id);
            const no_vel = h.filterAttributes(Buff, &[_]type{Pos}, &[_]type{Vel});
            try std.testing.expect(no_vel.len == 1);
            try std.testing.expect(no_vel[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(no_vel[0].valueAt(0).amount == 1);
            const with_vel = h.filterAttributes(Buff, &[_]type{ Pos, Vel }, null);
            try std.testing.expect(with_vel.len == 1);
            try std.testing.expect(with_vel[0].valueAt(0).amount == 2);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attribute batch commands mirror events" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const N: usize = 200;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            var values: [N]Buff = undefined;
            for (0..N) |i| {
                values[i] = .{ .amount = @intCast(i) };
            }
            try h.cmdSetAttributesEach(S.refs[0..], Buff, values[0..]);
            try std.testing.expectError(
                Ecs.EcsError.CountMismatch,
                h.cmdSetAttributesEach(S.refs[0..10], Buff, values[0..9]),
            );
        }
        fn wipe_even(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
            var evens: [N / 2]Ecs.EntityReference = undefined;
            var en: usize = 0;
            for (S.refs, 0..) |ref, i| {
                if (i % 2 == 0) {
                    evens[en] = ref;
                    en += 1;
                }
            }
            try h.cmdDestroyAttributesFor(evens[0..], Buff);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N / 2);
            var sum: u64 = 0;
            for (pages[0].attributeList()) |a| {
                try std.testing.expect(a.amount % 2 == 1);
                sum += a.amount;
            }
            try std.testing.expect(sum == N * N / 4);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.wipe_even, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "user attributes follow the entity across migrate" {
    const Ecs = ECS(.{ .{ Pos, Vel }, .{Pos} });
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{ Pos, Vel }, .{
                Pos{ .horizontal_coordinate = 1, .vertical_coordinate = 0 },
                Vel{ .horizontal_speed = 0, .vertical_speed = 0 },
            });
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Buff, .{ .amount = 42 });
        }
        fn move(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdMigrate(S.target, &[_]type{Pos}, true);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].arch_id == Ecs.archetypeId(&[_]type{Pos}));
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].valueAt(0).amount == 42);
            // Depth is preserved by migrate: still a depth-0 zone.
            try std.testing.expect(pages[0].depthCount() == 1);
            try std.testing.expect(pages[0].depthZone(0).?.len == 1);
            const e = pages[0].entityAt(0);
            try std.testing.expect(e.isAlive());
            try std.testing.expect(e.gen == S.target.gen +% 1);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.move, S.verify });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attribute rows ride depth zones across reparent" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        var r2: Ecs.EntityReference = undefined;
        var r3: Ecs.EntityReference = undefined;
        var c: Ecs.EntityReference = undefined;
        var g: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.r = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.r2 = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            S.r3 = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
            S.c = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 4,
                .vertical_coordinate = 0,
            }});
            S.g = try h.cmdCreateChild(S.c, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.c, Buff, .{ .amount = 10 });
            try h.cmdSetAttribute(S.g, Buff, .{ .amount = 20 });
        }
        fn move1(h: *Ecs.SystemHandler) anyerror!void {
            // Same depth (1 -> 1): rows stay in the depth-1 zone.
            try h.cmdReparent(S.c, S.r2);
        }
        fn move2(h: *Ecs.SystemHandler) anyerror!void {
            // The R2 subtree sinks one level.
            try h.cmdReparent(S.r2, S.r3);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            const page = &pages[0];
            try std.testing.expect(page.count() == 2);
            try std.testing.expect(page.depthCount() == 2);
            try std.testing.expect(page.depthZone(1) == null);
            try std.testing.expect(page.depthZone(2).?.len == 1);
            try std.testing.expect(page.depthZone(3).?.len == 1);
            // Zone views expose matching entities and mutable values.
            const z2 = page.zone(2);
            try std.testing.expect(z2.len() == 1);
            try std.testing.expect(z2.entities()[0].id == S.c.id);
            z2.values()[0].amount = 11;
            const z3 = page.zoneAt(1);
            try std.testing.expect(z3.depth() == 3);
            try std.testing.expect(z3.entities()[0].id == S.g.id);
            try std.testing.expect(z3.values()[0].amount == 20);
            try std.testing.expect((try h.getAttribute(S.c, Buff)).amount == 11);
        }
        fn detach(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdReparent(S.c, null);
        }
        fn verify_detached(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            const page = &pages[0];
            // C is a root again, G follows at depth 1.
            try std.testing.expect(page.depthZone(0).?.len == 1);
            try std.testing.expect(page.depthZone(1).?.len == 1);
            try std.testing.expect(page.depthZone(2) == null);
            try std.testing.expect((try h.getAttribute(S.g, Buff)).amount == 20);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.move1, S.move2, S.verify, S.detach, S.verify_detached });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "destroyed entities lose attributes, recycled slots start clean" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var first: Ecs.EntityReference = undefined;
        var second: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.first = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.first, Buff, .{ .amount = 7 });
        }
        fn kill1(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroy(S.first);
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allAttributes(Buff).len == 0);
            try std.testing.expectError(
                Ecs.EcsError.EntityIsNotAlive,
                h.getAttribute(S.first, Buff),
            );
        }
        fn respawn(h: *Ecs.SystemHandler) anyerror!void {
            S.second = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            try std.testing.expect(S.second.id == S.first.id);
        }
        fn verify_clean(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allAttributes(Buff).len == 0);
            try h.cmdSetAttribute(S.second, Buff, .{ .amount = 8 });
        }
        fn verify_set(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect((try h.getAttribute(S.second, Buff)).amount == 8);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.kill1, S.verify_gone, S.respawn, S.verify_clean, S.verify_set });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "zero-size attributes work end to end" {
    const Ecs = ECS(.{.{Pos}});
    const Tag = struct {};
    const S = struct {
        const S = @This();
        var target: Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.target, Tag, .{});
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Tag);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == 1);
            try std.testing.expect(pages[0].depthZone(0).?.len == 1);
            _ = try h.getAttribute(S.target, Tag);
            try h.cmdDestroyAttribute(pages[0].handleAt(0));
        }
        fn verify_gone(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allAttributes(Tag).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify, S.verify_gone });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "attribute limits warm up and trim" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const N: usize = 100;
    const S = struct {
        const S = @This();
        var refs: [N]Ecs.EntityReference = undefined;
        var mid_col_cap: usize = 0;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.refs[i] = ref;
            }
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            var values: [N]Buff = undefined;
            for (0..N) |i| {
                values[i] = .{ .amount = @intCast(i) };
            }
            try h.cmdSetAttributesEach(S.refs[0..], Buff, values[0..]);
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].count() == N);
            var sum: u64 = 0;
            for (pages[0].attributeList()) |a| {
                sum += a.amount;
            }
            try std.testing.expect(sum == N * (N - 1) / 2);
            const Store = Ecs.AttributeStore(Buff);
            S.mid_col_cap = Store.committed.items[0].entities.capacity;
        }
        fn wipe(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroyAttributes(Buff);
        }
        fn verify_wiped(h: *Ecs.SystemHandler) anyerror!void {
            try std.testing.expect(h.allAttributes(Buff).len == 0);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.emit, S.verify });
    const WipeApp = Ecs.Schedule(.{S.wipe});
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const handler = Ecs.SystemHandler{ .allocator = allocator };
    // Warmup pre-grows the slot maps.
    try handler.setAttributeLimits(Buff, .{ .slots = 500, .pending = 64, .events_per_page = 32, .pages = 2 });
    const Store = Ecs.AttributeStore(Buff);
    try std.testing.expect(Store.rows.items.len >= 500);
    try std.testing.expect(Store.page_pool.items.len == 2);
    // Tighter budgets trim at frame end; replace semantics apply.
    // Attributes persist, so the live page stays committed: only the pool
    // shells (once rows are destroyed) and the pending queue trim here.
    try handler.setAttributeLimits(Buff, .{ .events_per_page = 4, .pages = 1, .pending = 8 });
    try std.testing.expect(handler.attributeLimits(Buff).slots == null);
    try App.run(allocator);
    try std.testing.expect(S.mid_col_cap >= N);
    try std.testing.expect(Store.pending.capacity < N);
    // Wiping the attributes drops the page to the pool; the same frame end
    // trims the shell down to the budgets.
    try WipeApp.run(allocator);
    try std.testing.expect(Store.page_pool.items.len == 1);
    try std.testing.expect(Store.page_pool.items[0].entities.capacity < S.mid_col_cap);
    // Clearing restores grow-only behavior; re-emitting reuses the pool
    // shell, so it sits back in committed with a full page.
    handler.clearAttributeLimits(Buff);
    try App.run(allocator);
    try std.testing.expect(Store.committed.items.len == 1);
    try std.testing.expect(Store.committed.items[0].count() == N);
    try std.testing.expect(Store.page_pool.items.len == 0);
}
test "attribute zone rotation keeps rows and mappings exact" {
    const Ecs = ECS(.{.{Pos}});
    const Buff = struct { amount: u32 };
    const S = struct {
        const S = @This();
        var r: Ecs.EntityReference = undefined;
        var c1: Ecs.EntityReference = undefined;
        var c2: Ecs.EntityReference = undefined;
        var g: Ecs.EntityReference = undefined;
        var x: Ecs.EntityReference = undefined;
        var y: Ecs.EntityReference = undefined;
        var z: Ecs.EntityReference = undefined;
        var w: Ecs.EntityReference = undefined;
        fn spawn0(h: *Ecs.SystemHandler) anyerror!void {
            S.r = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }});
            S.c1 = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            S.c2 = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 3,
                .vertical_coordinate = 0,
            }});
            S.g = try h.cmdCreateChild(S.c1, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 4,
                .vertical_coordinate = 0,
            }});
        }
        fn emit0(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.r, Buff, .{ .amount = 1 });
            try h.cmdSetAttribute(S.c1, Buff, .{ .amount = 2 });
            try h.cmdSetAttribute(S.c2, Buff, .{ .amount = 3 });
            try h.cmdSetAttribute(S.g, Buff, .{ .amount = 4 });
        }
        fn vbase(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            try std.testing.expect(pages[0].depthCount() == 3);
            try std.testing.expect(pages[0].depthZone(0).?.len == 1);
            try std.testing.expect(pages[0].depthZone(1).?.len == 2);
            try std.testing.expect(pages[0].depthZone(2).?.len == 1);
        }
        fn rm_g(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroyAttributesFor(&[_]Ecs.EntityReference{S.g}, Buff);
        }
        fn spawn_x(h: *Ecs.SystemHandler) anyerror!void {
            S.x = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 5,
                .vertical_coordinate = 0,
            }});
        }
        fn set_x(h: *Ecs.SystemHandler) anyerror!void {
            // Inserts into zone 0 with a deeper zone present: rotation.
            try h.cmdSetAttribute(S.x, Buff, .{ .amount = 5 });
        }
        fn v1(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            const ents = pages[0].entityList();
            try std.testing.expect(ents.len == 4);
            // Rotation result: the fresh row lands at the zone tail while
            // untouched rows keep their positions.
            try std.testing.expect(ents[0].id == S.r.id);
            try std.testing.expect(ents[1].id == S.x.id);
            try std.testing.expect(ents[2].id == S.c2.id);
            try std.testing.expect(ents[3].id == S.c1.id);
            const z0 = pages[0].depthZone(0).?;
            const z1 = pages[0].depthZone(1).?;
            try std.testing.expect(z0.offset == 0 and z0.len == 2);
            try std.testing.expect(z1.offset == 2 and z1.len == 2);
            try std.testing.expect((try h.getAttribute(S.r, Buff)).amount == 1);
            try std.testing.expect((try h.getAttribute(S.x, Buff)).amount == 5);
            try std.testing.expect((try h.getAttribute(S.c1, Buff)).amount == 2);
            try std.testing.expect((try h.getAttribute(S.c2, Buff)).amount == 3);
        }
        fn rm_c1(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroyAttributesFor(&[_]Ecs.EntityReference{S.c1}, Buff);
        }
        fn v2(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            const ents = pages[0].entityList();
            try std.testing.expect(ents.len == 3);
            try std.testing.expect(ents[0].id == S.r.id);
            try std.testing.expect(ents[1].id == S.x.id);
            try std.testing.expect(ents[2].id == S.c2.id);
            var sum: u64 = 0;
            for (pages[0].attributeList()) |a| {
                sum += a.amount;
            }
            try std.testing.expect(sum == 9);
            try std.testing.expectError(
                Ecs.EcsError.AttributeNotFound,
                h.getAttribute(S.c1, Buff),
            );
        }
        fn rm_x(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdDestroyAttributesFor(&[_]Ecs.EntityReference{S.x}, Buff);
        }
        fn v3(h: *Ecs.SystemHandler) anyerror!void {
            // Cascade: deeper zone boundary rotated down.
            const pages = h.allAttributes(Buff);
            const ents = pages[0].entityList();
            try std.testing.expect(ents.len == 2);
            try std.testing.expect(ents[0].id == S.r.id);
            try std.testing.expect(ents[1].id == S.c2.id);
            try std.testing.expect(pages[0].depthZone(0).?.len == 1);
            try std.testing.expect(pages[0].depthZone(1).?.len == 1);
            var sum: u64 = 0;
            for (pages[0].attributeList()) |a| {
                sum += a.amount;
            }
            try std.testing.expect(sum == 4);
        }
        fn spawn_yz(h: *Ecs.SystemHandler) anyerror!void {
            S.y = try h.cmdCreateChild(S.r, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 6,
                .vertical_coordinate = 0,
            }});
            S.z = try h.cmdCreateChild(S.y, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 7,
                .vertical_coordinate = 0,
            }});
        }
        fn set_yz(h: *Ecs.SystemHandler) anyerror!void {
            try h.cmdSetAttribute(S.y, Buff, .{ .amount = 6 });
            try h.cmdSetAttribute(S.z, Buff, .{ .amount = 7 });
        }
        fn spawn_w(h: *Ecs.SystemHandler) anyerror!void {
            S.w = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 8,
                .vertical_coordinate = 0,
            }});
        }
        fn set_w(h: *Ecs.SystemHandler) anyerror!void {
            // Inserts into zone 0 with two deeper zones: full rotation.
            try h.cmdSetAttribute(S.w, Buff, .{ .amount = 8 });
        }
        fn v5(h: *Ecs.SystemHandler) anyerror!void {
            const pages = h.allAttributes(Buff);
            const ents = pages[0].entityList();
            try std.testing.expect(ents.len == 5);
            try std.testing.expect(ents[0].id == S.r.id);
            try std.testing.expect(ents[1].id == S.w.id);
            try std.testing.expect(ents[2].id == S.y.id);
            try std.testing.expect(ents[3].id == S.c2.id);
            try std.testing.expect(ents[4].id == S.z.id);
            const z0 = pages[0].depthZone(0).?;
            const z1 = pages[0].depthZone(1).?;
            const z2 = pages[0].depthZone(2).?;
            try std.testing.expect(z0.offset == 0 and z0.len == 2);
            // Zone 1 holds both depth-1 members: Y and the earlier C2.
            try std.testing.expect(z1.offset == 2 and z1.len == 2);
            try std.testing.expect(z2.offset == 4 and z2.len == 1);
            try std.testing.expect((try h.getAttribute(S.r, Buff)).amount == 1);
            try std.testing.expect((try h.getAttribute(S.w, Buff)).amount == 8);
            try std.testing.expect((try h.getAttribute(S.y, Buff)).amount == 6);
            try std.testing.expect((try h.getAttribute(S.c2, Buff)).amount == 3);
            try std.testing.expect((try h.getAttribute(S.z, Buff)).amount == 7);
        }
    };
    const App = Ecs.Schedule(.{
        S.spawn0,
        S.emit0,
        S.vbase,
        S.rm_g,
        S.spawn_x,
        S.set_x,
        S.v1,
        S.rm_c1,
        S.v2,
        S.rm_x,
        S.v3,
        S.spawn_yz,
        S.set_yz,
        S.spawn_w,
        S.set_w,
        S.v5,
    });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
test "mass children keep creation order and consistent links" {
    const Ecs = ECS(.{.{Pos}});
    const N: u32 = 10000;
    const S = struct {
        const S = @This();
        var parent: Ecs.EntityReference = undefined;
        var kids: [N]Ecs.EntityReference = undefined;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            S.parent = try h.cmdCreate(&[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 0,
                .vertical_coordinate = 0,
            }});
            const created = try h.cmdCreateChildren(S.parent, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 1,
                .vertical_coordinate = 0,
            }}, N);
            for (created, 0..) |ref, i| {
                S.kids[i] = ref;
            }
        }
        fn verify(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(try S.parent.childCount() == N);
            // Forward walk matches creation order exactly.
            var it = S.parent.children();
            var i: usize = 0;
            while (it.next()) |c| {
                try std.testing.expect(c.id == S.kids[i].id);
                try std.testing.expect(c.gen == S.kids[i].gen);
                try std.testing.expect((try c.depthOf()) == 1);
                try std.testing.expect(c.parent().?.id == S.parent.id);
                i += 1;
            }
            try std.testing.expect(i == N);
            // Backward walk from the tail reaches every child once.
            var back = S.kids[N - 1];
            var j: usize = N;
            while (true) {
                try std.testing.expect(back.id == S.kids[j - 1].id);
                j -= 1;
                if (j == 0) {
                    break;
                }
                back = back.prevSibling().?;
            }
            try std.testing.expect(back.prevSibling() == null);
        }
        fn detach_last_and_reattach(h: *Ecs.SystemHandler) anyerror!void {
            // Detaching the tail must move the tail pointer back.
            try h.cmdReparent(S.kids[N - 1], null);
        }
        fn attach_new(h: *Ecs.SystemHandler) anyerror!void {
            // A fresh child must land exactly at the end, after the
            // previously second-to-last kid.
            const fresh = try h.cmdCreateChild(S.parent, &[_]type{Pos}, .{Pos{
                .horizontal_coordinate = 2,
                .vertical_coordinate = 0,
            }});
            S.kids[N - 1] = fresh;
        }
        fn verify_tail(h: *Ecs.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect(try S.parent.childCount() == N);
            var it = S.parent.children();
            var last: ?Ecs.EntityReference = null;
            var total: usize = 0;
            while (it.next()) |c| {
                last = c;
                total += 1;
            }
            try std.testing.expect(total == N);
            try std.testing.expect(last.?.id == S.kids[N - 1].id);
            try std.testing.expect(last.?.nextSibling() == null);
        }
    };
    const App = Ecs.Schedule(.{ S.spawn, S.verify, S.detach_last_and_reattach, S.attach_new, S.verify_tail });
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    try App.run(allocator);
}
