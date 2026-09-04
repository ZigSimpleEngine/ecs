const std = @import("std");
/// Builds a read-only view over a standard unmanaged array list.
/// - `Element` - element type stored in the wrapped list.
/// Returns `type` - view type exposing only read access to the list.
pub fn ReadOnlyList(comptime Element: type) type {
    return struct {
        const Self = @This();
        /// Pointer to the wrapped list. Reads always observe live data.
        source: *const std.ArrayListUnmanaged(Element),
        /// Wraps an existing list without copying it.
        /// - `source` - list to observe.
        /// Returns `Self` - read-only view bound to the given list.
        pub fn init(source: *const std.ArrayListUnmanaged(Element)) Self {
            return Self{
                .source = source,
            };
        }
        /// Counts stored elements.
        /// - `self` - view to inspect.
        /// Returns `usize` - current element count.
        pub fn count(self: *const Self) usize {
            return self.source.items.len;
        }
        /// Exposes the whole backing slice for iteration.
        /// - `self` - view to inspect.
        /// Returns `[]const Element` - read-only slice of all elements.
        pub fn items(self: *const Self) []const Element {
            return self.source.items;
        }
        /// Fetches a single element by position.
        /// - `self` - view to inspect.
        /// - `index` - element position.
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
/// Builds an isolated Entity Component System namespace.
/// - `max_archetypes` - per-component cap on tracked archetypes.
/// - `max_supersets` - per-archetype cap on tracked supersets.
/// Returns `type` - ECS namespace with its own counters and storage.
pub fn ECS(
    comptime max_archetypes: u32,
    comptime max_supersets: u32,
) type {
    return struct {
        const Ecs = @This();
        /// Next fresh entity id. Equals the record count while no slots are recycled.
        var next_entity_id: u32 = 0;
        /// Next component type id. Handed out lazily on first use.
        var next_component_id: u32 = 0;
        /// Next archetype id. Handed out lazily on first use.
        var next_archetype_id: u32 = 0;
        /// All entity records by id. A record id always matches its position here.
        var entities: std.ArrayListUnmanaged(Entity) = .empty;
        /// Stack of freed entity ids ready for reuse.
        var free_ids: std.ArrayListUnmanaged(u32) = .empty;
        /// Every registered archetype. Used to maintain superset links.
        var registry: std.ArrayListUnmanaged(*ArchetypeInfo) = .empty;
        /// Component archetype lists, tracked here so deinit can free them.
        var tracked: std.ArrayListUnmanaged(*std.ArrayListUnmanaged(*ArchetypeInfo)) = .empty;
        /// Failure modes of ECS operations, including allocator failures.
        pub const EcsError = std.mem.Allocator.Error || error{
            /// Reserved for lookups of an id that was never assigned to any entity.
            EntitySlotNeverCreated,
            /// Operation requires a live entity but the reference is stale.
            EntityIsNotAlive,
            /// Requested position lies outside the storage range.
            IndexOutOfBounds,
            /// A component already tracks the maximum number of archetypes.
            ArchetypeListOverflow,
            /// An archetype already tracks the maximum number of supersets.
            SupersetListOverflow,
            /// Requested component is not stored in this archetype.
            ComponentNotFoundInArchetype,
        };
        /// Lightweight entity handle. Stays small enough to copy by value.
        pub const EntityReference = packed struct {
            /// Entity slot id. Matches the record position in storage.
            id: u24,
            /// Slot generation. Bumped on every destroy and migrate.
            gen: u8,
            /// Checks whether this id was ever assigned to an entity.
            /// - `self` - reference to inspect.
            /// Returns `bool` - true when a record slot exists for the id.
            pub fn exists(self: *const EntityReference) bool {
                const entity_index: u32 = self.id;
                return entity_index < Ecs.entities.items.len;
            }
            /// Checks whether the reference still points at a live entity.
            /// - `self` - reference to inspect.
            /// Returns `bool` - true when the slot exists and generations match.
            pub fn isAlive(self: *const EntityReference) bool {
                if (!self.exists()) {
                    return false;
                }
                const entity_index: u32 = self.id;
                const stored: *const Entity = &Ecs.entities.items[entity_index];
                return stored.reference.gen == self.gen;
            }
            /// Loads the full entity record behind this reference.
            /// - `self` - reference to resolve.
            /// Returns `?Entity` - stored record copy, or null when not alive.
            pub fn entity(self: *const EntityReference) ?Entity {
                if (!self.isAlive()) {
                    return null;
                }
                const entity_index: u32 = self.id;
                return Ecs.entities.items[entity_index];
            }
            /// Destroys the referenced entity and recycles its slot.
            /// - `self` - reference to destroy. Must be alive.
            /// - `allocator` - funds the free-slot bookkeeping.
            pub fn destroy(self: *const EntityReference, allocator: std.mem.Allocator) Ecs.EcsError!void {
                if (!self.isAlive()) {
                    return Ecs.EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                const record: *Entity = &Ecs.entities.items[entity_index];
                const handle: *ArchetypeInfo = record.handle;
                const index: u32 = record.index;
                const displaced: ?EntityReference =
                    handle.remove(index);
                if (displaced) |relocated| {
                    const relocated_index: u32 = relocated.id;
                    Ecs.entities.items[relocated_index].index = index;
                }
                const bumped: u8 = record.reference.gen +% 1;
                record.reference.gen = bumped;
                try Ecs.free_ids.append(allocator, entity_index);
            }
            /// Moves the entity into another archetype, optionally copying shared data.
            /// - `self` - reference to move. Must be alive.
            /// - `allocator` - funds the destination slot.
            /// - `dest` - archetype receiving the entity.
            /// - `copy` - when true, shared component bytes are carried over.
            /// Returns `EntityReference` - refreshed reference with a bumped generation.
            pub fn migrate(
                self: *const EntityReference,
                allocator: std.mem.Allocator,
                dest: *ArchetypeInfo,
                copy: bool,
            ) Ecs.EcsError!EntityReference {
                if (!self.isAlive()) {
                    return Ecs.EcsError.EntityIsNotAlive;
                }
                const entity_index: u32 = self.id;
                const record: *Entity = &Ecs.entities.items[entity_index];
                const source: *ArchetypeInfo = record.handle;
                const source_index: u32 = record.index;
                const next = EntityReference{
                    .id = self.id,
                    .gen = self.gen +% 1,
                };
                const dest_index: u32 =
                    try dest.add(allocator, &next);
                if (copy) {
                    copyShared(
                        source,
                        source_index,
                        dest,
                        dest_index,
                    );
                }
                const displaced: ?EntityReference =
                    source.remove(source_index);
                if (displaced) |relocated| {
                    const relocated_index: u32 = relocated.id;
                    Ecs.entities.items[relocated_index].index =
                        source_index;
                }
                record.reference = next;
                record.handle = dest;
                record.index = dest_index;
                return record.reference;
            }
        };
        /// Full entity record stored in global storage.
        pub const Entity = struct {
            /// Handle identifying this entity. Stale copies compare unequal.
            reference: EntityReference,
            /// Archetype currently owning the component data.
            handle: *ArchetypeInfo,
            /// Row position inside the owning archetype storage.
            index: u32,
            /// Creates an entity inside the given archetype, reusing a free slot when possible.
            /// - `allocator` - funds record and archetype row allocation.
            /// - `dest` - archetype receiving the new entity.
            /// Returns `Entity` - freshly stored record copy.
            pub fn create(
                allocator: std.mem.Allocator,
                dest: *ArchetypeInfo,
            ) Ecs.EcsError!Entity {
                var new_id: u32 = 0;
                var new_gen: u8 = 0;
                var slot: *Entity = undefined;
                if (Ecs.free_ids.pop()) |recycled| {
                    new_id = recycled;
                    slot = &Ecs.entities.items[new_id];
                    new_gen = slot.reference.gen;
                } else {
                    new_id = Ecs.next_entity_id;
                    Ecs.next_entity_id += 1;
                    const placeholder = Entity{
                        .reference = EntityReference{
                            .id = @intCast(new_id),
                            .gen = 0,
                        },
                        .handle = dest,
                        .index = 0,
                    };
                    try Ecs.entities.append(allocator, placeholder);
                    slot = &Ecs.entities.items[new_id];
                    new_gen = 0;
                }
                const reference = EntityReference{
                    .id = @intCast(new_id),
                    .gen = new_gen,
                };
                const index: u32 =
                    try dest.add(allocator, &reference);
                slot.reference = reference;
                slot.handle = dest;
                slot.index = index;
                return slot.*;
            }
        };
        /// Runtime descriptor of a single component type.
        pub const ComponentInfo = struct {
            /// Unique component id assigned on first use.
            id: u32,
            /// Byte size of one component value. Drives raw copies.
            size: usize,
            /// Byte alignment of the component type.
            alignment: usize,
            /// Fully qualified component type name. Used for canonical sorting.
            name: []const u8,
            /// Live list of archetypes containing this component.
            archetype_storage: *const std.ArrayListUnmanaged(*ArchetypeInfo),
            /// Read-only view over archetypes containing this component.
            /// - `self` - descriptor to inspect.
            /// Returns `ReadOnlyList` - live view of the archetype list.
            pub fn archetypes(self: *const ComponentInfo) ReadOnlyList(*ArchetypeInfo) {
                return ReadOnlyList(*ArchetypeInfo).init(self.archetype_storage);
            }
        };
        /// Type-erased operation set of one archetype storage.
        pub const VTable = struct {
            /// Appends a row for the given reference.
            add: *const fn (
                data: *anyopaque,
                allocator: std.mem.Allocator,
                reference: *const EntityReference,
            ) Ecs.EcsError!u32,
            /// Removes the row at the given position via swap with the last row.
            remove: *const fn (
                data: *anyopaque,
                index: u32,
            ) ?EntityReference,
            /// Counts stored rows.
            count: *const fn (
                data: *const anyopaque,
            ) u32,
            /// Fetches the reference stored at the given position.
            entity: *const fn (
                data: *const anyopaque,
                index: u32,
            ) ?EntityReference,
            /// Reads one component value as raw bytes.
            raw: *const fn (
                data: *const anyopaque,
                info: *const ComponentInfo,
                index: u32,
            ) ?[]const u8,
            /// Exposes one component value as writable raw bytes.
            raw_mut: *const fn (
                data: *anyopaque,
                info: *const ComponentInfo,
                index: u32,
            ) ?[]u8,
            /// Releases every list owned by the storage.
            deinit: *const fn (
                data: *anyopaque,
                allocator: std.mem.Allocator,
            ) void,
        };
        /// Runtime descriptor of a single archetype.
        pub const ArchetypeInfo = struct {
            /// Unique archetype id assigned on first use.
            id: u32,
            /// Descriptors of the stored component types.
            components: []const *const ComponentInfo,
            /// Archetypes strictly containing this one. Mutated during registration.
            superset_storage: std.ArrayListUnmanaged(*ArchetypeInfo),
            /// Type-erased pointer to the owned component storage.
            data: *anyopaque,
            /// Operation set dispatching to the concrete storage type.
            vtable: *const VTable,
            /// Read-only view over registered superset archetypes.
            /// - `self` - descriptor to inspect.
            /// Returns `ReadOnlyList` - live view of the superset list.
            pub fn supersets(self: *const ArchetypeInfo) ReadOnlyList(*ArchetypeInfo) {
                return ReadOnlyList(*ArchetypeInfo).init(&self.superset_storage);
            }
            /// Counts entities stored in this archetype.
            /// - `self` - descriptor to inspect.
            /// Returns `u32` - current row count.
            pub fn count(self: *const ArchetypeInfo) u32 {
                return self.vtable.count(self.data);
            }
            /// Appends a row for the given reference.
            /// - `self` - descriptor receiving the row.
            /// - `allocator` - funds row allocation.
            /// - `reference` - handle stored alongside the components.
            /// Returns `u32` - position of the new row.
            pub fn add(
                self: *ArchetypeInfo,
                allocator: std.mem.Allocator,
                reference: *const EntityReference,
            ) Ecs.EcsError!u32 {
                return try self.vtable.add(
                    self.data,
                    allocator,
                    reference,
                );
            }
            /// Removes the row at the given position via swap with the last row.
            /// - `self` - descriptor owning the row.
            /// - `index` - row position to remove.
            /// Returns `?EntityReference` - relocated reference, or null when the last row was removed.
            pub fn remove(
                self: *ArchetypeInfo,
                index: u32,
            ) ?EntityReference {
                return self.vtable.remove(
                    self.data,
                    index,
                );
            }
            /// Checks whether the archetype stores the given component.
            /// - `self` - descriptor to inspect.
            /// - `info` - component descriptor to look up.
            /// Returns `bool` - true when a matching component id is stored.
            pub fn has(self: *const ArchetypeInfo, info: *const ComponentInfo) bool {
                for (self.components) |known| {
                    if (known.id == info.id) {
                        return true;
                    }
                }
                return false;
            }
        };
        /// Links a superset into the owner superset list unless already present.
        /// - `allocator` - funds list growth.
        /// - `owner` - archetype receiving the link.
        /// - `super` - strictly larger archetype to link.
        fn addSuperset(
            allocator: std.mem.Allocator,
            owner: *ArchetypeInfo,
            super: *ArchetypeInfo,
        ) EcsError!void {
            for (owner.superset_storage.items) |known| {
                if (known == super) {
                    return;
                }
            }
            if (owner.superset_storage.items.len >= max_supersets) {
                return EcsError.SupersetListOverflow;
            }
            try owner.superset_storage.append(allocator, super);
        }
        /// Copies bytes of components shared by two archetype rows.
        /// - `source` - archetype to read from.
        /// - `source_index` - row position in the source storage.
        /// - `dest` - archetype to write to.
        /// - `dest_index` - row position in the destination storage.
        fn copyShared(
            source: *const ArchetypeInfo,
            source_index: u32,
            dest: *ArchetypeInfo,
            dest_index: u32,
        ) void {
            for (source.components) |src| {
                for (dest.components) |dst| {
                    if (src.id != dst.id) {
                        continue;
                    }
                    const src_bytes: ?[]const u8 =
                        source.vtable.raw(
                            source.data,
                            src,
                            source_index,
                        );
                    const dst_bytes: ?[]u8 =
                        dest.vtable.raw_mut(
                            dest.data,
                            dst,
                            dest_index,
                        );
                    if (src_bytes) |source_part| {
                        if (dst_bytes) |dest_part| {
                            const byte_count: usize = @min(source_part.len, dest_part.len);
                            @memcpy(dest_part[0..byte_count], source_part[0..byte_count]);
                        }
                    }
                }
            }
        }
        /// Detects types produced by the Component factory.
        /// - `Candidate` - type to inspect.
        /// Returns `bool` - true for component wrappers only.
        pub fn isComponent(comptime Candidate: type) bool {
            const type_info = @typeInfo(Candidate);
            if (type_info != .@"struct") {
                return false;
            }
            if (!@hasDecl(Candidate, "kind")) {
                return false;
            }
            if (!@hasDecl(Candidate, "ComponentType")) {
                return false;
            }
            return Candidate.kind == .component;
        }
        /// Detects types produced by the Archetype factories.
        /// - `Candidate` - type to inspect.
        /// Returns `bool` - true for archetype types only.
        pub fn isArchetype(comptime Candidate: type) bool {
            const type_info = @typeInfo(Candidate);
            if (type_info != .@"struct") {
                return false;
            }
            if (!@hasDecl(Candidate, "kind")) {
                return false;
            }
            if (!@hasDecl(Candidate, "components")) {
                return false;
            }
            return Candidate.kind == .archetype;
        }
        /// Builds the component wrapper for a plain struct type. Rejects archetypes at compile time.
        /// - `Raw` - struct type, or an existing component wrapper to reuse.
        /// Returns `type` - component wrapper owning the unique id and the runtime descriptor.
        pub fn Component(comptime Raw: type) type {
            if (Ecs.isArchetype(Raw)) {
                @compileError("Archetype cannot be used as a component. Pass a plain struct instead.");
            }
            return struct {
                const Self = @This();
                /// Marks this type as a component for isComponent checks.
                pub const kind = .component;
                /// The unwrapped struct type carrying the payload.
                pub const ComponentType: type = if (Ecs.isComponent(Raw))
                    Raw.ComponentType
                else
                    Raw;
                comptime {
                    if (@typeInfo(ComponentType) != .@"struct") {
                        @compileError("Component must be a struct type.");
                    }
                }
                /// Lazily assigned component id. Stable for the same underlying type.
                var id_storage: ?u32 = null;
                /// Archetypes currently holding this component.
                var archetypes: std.ArrayListUnmanaged(*Ecs.ArchetypeInfo) = .empty;
                /// Single cached runtime descriptor shared by all callers.
                var cache: ?Ecs.ComponentInfo = null;
                /// Returns the lazily assigned component id.
                /// Returns `u32` - stable component id.
                pub fn id() u32 {
                    if (Self.id_storage == null) {
                        Self.id_storage = Ecs.next_component_id;
                        Ecs.next_component_id += 1;
                    }
                    return Self.id_storage.?;
                }

                /// Returns the cached runtime component descriptor.
                /// Returns `*const ComponentInfo` - shared descriptor, built on first call.
                pub fn info() *const Ecs.ComponentInfo {
                    _ = Self.id();
                    if (Self.cache == null) {
                        Self.cache = Ecs.ComponentInfo{
                            .id = Self.id_storage.?,
                            .size = @sizeOf(Self.ComponentType),
                            .alignment = @alignOf(Self.ComponentType),
                            .name = @typeName(Self.ComponentType),
                            .archetype_storage = &Self.archetypes,
                        };
                    }
                    return &Self.cache.?;
                }
                /// Records an archetype as a holder of this component.
                /// - `allocator` - funds list growth.
                /// - `handle` - archetype to record.
                fn attach(
                    allocator: std.mem.Allocator,
                    handle: *Ecs.ArchetypeInfo,
                ) Ecs.EcsError!void {
                    for (Self.archetypes.items) |known| {
                        if (known == handle) {
                            return;
                        }
                    }
                    if (Self.archetypes.items.len >= max_archetypes) {
                        return Ecs.EcsError.ArchetypeListOverflow;
                    }
                    if (Self.archetypes.items.len == 0) {
                        try Ecs.tracked.append(
                            allocator,
                            &Self.archetypes,
                        );
                    }
                    try Self.archetypes.append(allocator, handle);
                }
            };
        }
        /// Normalizes component input: unwraps wrappers, flattens archetypes, dedups and sorts by type name.
        /// - `input` - mixed component, wrapper and archetype types.
        /// Returns `[]const type` - canonical, sorted, unique type list.
        pub fn GetComponentsTypes(comptime input: []const type) []const type {
            return comptime canon: {
                const max_count: usize = 512;
                var flat: [max_count]type = undefined;
                var flat_len: usize = 0;
                for (input) |item| {
                    if (Ecs.isArchetype(item)) {
                        for (item.components) |nested| {
                            if (flat_len >= max_count) {
                                @compileError("Too many components after archetype flattening.");
                            }
                            flat[flat_len] = nested;
                            flat_len += 1;
                        }
                    } else if (Ecs.isComponent(item)) {
                        if (flat_len >= max_count) {
                            @compileError("Too many components.");
                        }
                        flat[flat_len] = item.ComponentType;
                        flat_len += 1;
                    } else {
                        if (@typeInfo(item) != .@"struct") {
                            @compileError("Every component must be a struct type.");
                        }
                        if (item == Entity or item == EntityReference) {
                            @compileError("Entity and EntityReference cannot be components.");
                        }
                        if (flat_len >= max_count) {
                            @compileError("Too many components.");
                        }
                        flat[flat_len] = item;
                        flat_len += 1;
                    }
                }
                var unique: [max_count]type = undefined;
                var total: usize = 0;
                for (flat[0..flat_len]) |candidate| {
                    var duplicate: bool = false;
                    for (unique[0..total]) |existing| {
                        if (existing == candidate) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        unique[total] = candidate;
                        total += 1;
                    }
                }
                var outer: usize = 0;
                while (outer < total) : (outer += 1) {
                    var inner: usize = outer + 1;
                    while (inner < total) : (inner += 1) {
                        const left: []const u8 = @typeName(unique[outer]);
                        const right: []const u8 = @typeName(unique[inner]);
                        if (std.mem.order(u8, right, left) == .lt) {
                            const swap: type = unique[outer];
                            unique[outer] = unique[inner];
                            unique[inner] = swap;
                        }
                    }
                }
                if (total == 0) {
                    @compileError("Archetype must contain at least one component.");
                }
                var ordered: [max_count]type = undefined;
                for (unique[0..total], 0..) |value, offset| {
                    ordered[offset] = value;
                }
                const Keep = struct {
                    const values: [max_count]type = ordered;
                    const count: usize = total;
                };
                break :canon Keep.values[0..Keep.count];
            };
        }
        /// Builds an archetype from input types, normalizing away input order.
        /// - `input` - component, wrapper or archetype types.
        /// Returns `type` - canonical archetype type.
        pub fn Archetype(comptime input: []const type) type {
            const canonical: []const type =
                Ecs.GetComponentsTypes(input);
            return Ecs.CreateArchetype(canonical);
        }
        /// Builds the SOA storage type for one archetype from a tuple of component lists.
        /// - `Tuple` - tuple type of ArrayListUnmanaged, one per component.
        /// Returns `type` - structure-of-arrays storage with component columns and entity refs.
        pub fn ArchetypeData(comptime Tuple: type) type {
            return struct {
                const Self = @This();
                /// One column per component type. Indexed by the tuple position.
                lists: Tuple,
                /// One row per stored entity, parallel to the component columns.
                refs: std.ArrayListUnmanaged(EntityReference) = .empty,
                /// Locates the column index storing the given component type.
                /// - `Target` - component type to locate.
                /// Returns `usize` - tuple field index, or a compile error when absent.
                fn indexOf(comptime Target: type) usize {
                    return comptime search_block: {
                        const type_info = @typeInfo(Tuple).@"struct";
                        for (type_info.fields, 0..) |field, field_index| {
                            const List: type = field.type;
                            switch (@typeInfo(List)) {
                                .@"struct" => |list_info| {
                                    for (list_info.fields) |member| {
                                        switch (@typeInfo(member.type)) {
                                            .pointer => |ptr| {
                                                if (std.mem.eql(u8, member.name, "items") and
                                                    ptr.child == Target)
                                                {
                                                    break :search_block field_index;
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                        @compileError("Requested component type is not stored in this archetype.");
                    };
                }
                /// Counts stored rows.
                /// - `self` - storage to inspect.
                /// Returns `u32` - current row count.
                pub fn count(self: *const Self) u32 {
                    return @intCast(self.refs.items.len);
                }
                /// Checks whether a row exists at the given position.
                /// - `self` - storage to inspect.
                /// - `index` - row position.
                /// Returns `bool` - true when the position is in range.
                pub fn exists(
                    self: *const Self,
                    index: u32,
                ) bool {
                    return index < self.refs.items.len;
                }
                /// Fetches the entity reference stored at the given position.
                /// - `self` - storage to inspect.
                /// - `index` - row position.
                /// Returns `EntityReference` - reference stored in the row.
                pub fn entity(
                    self: *const Self,
                    index: u32,
                ) Ecs.EcsError!EntityReference {
                    if (!self.exists(index)) {
                        return Ecs.EcsError.IndexOutOfBounds;
                    }
                    return self.refs.items[index];
                }
                /// Returns a read-only pointer to one component value.
                /// - `self` - storage to inspect.
                /// - `Target` - component type to fetch.
                /// - `index` - row position.
                /// Returns `*const Target` - pointer into the component column.
                pub fn get(
                    self: *const Self,
                    comptime Target: type,
                    index: u32,
                ) Ecs.EcsError!*const Target {
                    if (@typeInfo(Target) != .@"struct") {
                        @compileError("Requested component must be a struct type.");
                    }
                    if (Target == Entity or Target == EntityReference) {
                        @compileError("Use entity for EntityReference, not get.");
                    }
                    const column: usize = comptime
                        Self.indexOf(Target);
                    const column_list: *const std.ArrayListUnmanaged(Target) =
                        &self.lists[column];
                    if (index >= column_list.items.len) {
                        return Ecs.EcsError.IndexOutOfBounds;
                    }
                    return &column_list.items[index];
                }
                /// Returns a mutable pointer to one component value.
                /// - `self` - storage to mutate.
                /// - `Target` - component type to fetch.
                /// - `index` - row position.
                /// Returns `*Target` - mutable pointer into the component column.
                pub fn getMut(
                    self: *Self,
                    comptime Target: type,
                    index: u32,
                ) Ecs.EcsError!*Target {
                    if (@typeInfo(Target) != .@"struct") {
                        @compileError("Requested component must be a struct type.");
                    }
                    if (Target == Entity or Target == EntityReference) {
                        @compileError("Use entity for EntityReference, not get.");
                    }
                    const column: usize = comptime
                        Self.indexOf(Target);
                    const column_list: *std.ArrayListUnmanaged(Target) =
                        &self.lists[column];
                    if (index >= column_list.items.len) {
                        return Ecs.EcsError.IndexOutOfBounds;
                    }
                    return &column_list.items[index];
                }
                /// Exposes a whole component column as a read-only list.
                /// - `self` - storage to inspect.
                /// - `Target` - component type to expose.
                /// Returns `ReadOnlyList` - live view of the component column.
                pub fn list(
                    self: *const Self,
                    comptime Target: type,
                ) ReadOnlyList(Target) {
                    if (@typeInfo(Target) != .@"struct") {
                        @compileError("Requested component must be a struct type.");
                    }
                    if (Target == Entity or Target == EntityReference) {
                        @compileError("EntityReference list is accessed via entities.");
                    }
                    const column: usize = comptime
                        Self.indexOf(Target);
                    const column_list: *const std.ArrayListUnmanaged(Target) =
                        &self.lists[column];
                    return ReadOnlyList(Target).init(column_list);
                }
                /// Exposes the entity reference column as a read-only list.
                /// - `self` - storage to inspect.
                /// Returns `ReadOnlyList` - live view of the reference column.
                pub fn entities(self: *const Self) ReadOnlyList(EntityReference) {
                    return ReadOnlyList(EntityReference).init(&self.refs);
                }
                /// Reads one component value as raw bytes, matched by runtime descriptor.
                /// - `self` - storage to inspect.
                /// - `info` - component descriptor to match.
                /// - `index` - row position.
                /// Returns `?[]const u8` - byte slice, or null when absent or out of range.
                pub fn raw(
                    self: *const Self,
                    info: *const ComponentInfo,
                    index: u32,
                ) ?[]const u8 {
                    const type_info = @typeInfo(Tuple).@"struct";
                    inline for (type_info.fields, 0..) |field, field_index| {
                        const List: type = field.type;
                        switch (@typeInfo(List)) {
                            .@"struct" => |list_info| {
                                inline for (list_info.fields) |member| {
                                    switch (@typeInfo(member.type)) {
                                        .pointer => |ptr| {
                                            const Element: type = ptr.child;
                                            const wanted: u32 =
                                                Ecs.Component(Element).id();
                                            const matches: bool =
                                                std.mem.eql(u8, member.name, "items");
                                            if (matches and
                                                wanted == info.id)
                                            {
                                                const column_list: *const std.ArrayListUnmanaged(Element) =
                                                    &self.lists[field_index];
                                                if (index >= column_list.items.len) {
                                                    return null;
                                                }
                                                const element: *const Element =
                                                    &column_list.items[index];
                                    const bytes: [*]const u8 = @ptrCast(element);
                                    return bytes[0..@sizeOf(Element)];
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    return null;
                }
                /// Exposes one component value as writable raw bytes, matched by runtime descriptor.
                /// - `self` - storage to mutate.
                /// - `info` - component descriptor to match.
                /// - `index` - row position.
                /// Returns `?[]u8` - writable byte slice, or null when absent or out of range.
                pub fn rawMut(
                    self: *Self,
                    info: *const ComponentInfo,
                    index: u32,
                ) ?[]u8 {
                    const type_info = @typeInfo(Tuple).@"struct";
                    inline for (type_info.fields, 0..) |field, field_index| {
                        const List: type = field.type;
                        switch (@typeInfo(List)) {
                            .@"struct" => |list_info| {
                                inline for (list_info.fields) |member| {
                                    switch (@typeInfo(member.type)) {
                                        .pointer => |ptr| {
                                            const Element: type = ptr.child;
                                            const wanted: u32 =
                                                Ecs.Component(Element).id();
                                            const matches: bool =
                                                std.mem.eql(u8, member.name, "items");
                                            if (matches and
                                                wanted == info.id)
                                            {
                                                const column_list: *std.ArrayListUnmanaged(Element) =
                                                    &self.lists[field_index];
                                                if (index >= column_list.items.len) {
                                                    return null;
                                                }
                                                const element: *Element =
                                                    &column_list.items[index];
                                    const bytes: [*]u8 = @ptrCast(element);
                                    return bytes[0..@sizeOf(Element)];
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    return null;
                }
                /// Exposes a whole component column as raw bytes, matched by runtime descriptor.
                /// - `self` - storage to inspect.
                /// - `info` - component descriptor to match.
                /// Returns `?[]const u8` - byte slice of the whole column, or null when absent.
                pub fn rawList(
                    self: *const Self,
                    info: *const ComponentInfo,
                ) ?[]const u8 {
                    const type_info = @typeInfo(Tuple).@"struct";
                    inline for (type_info.fields, 0..) |field, field_index| {
                        const List: type = field.type;
                        switch (@typeInfo(List)) {
                            .@"struct" => |list_info| {
                                inline for (list_info.fields) |member| {
                                    switch (@typeInfo(member.type)) {
                                        .pointer => |ptr| {
                                            const Element: type = ptr.child;
                                            const wanted: u32 =
                                                Ecs.Component(Element).id();
                                            const matches: bool =
                                                std.mem.eql(u8, member.name, "items");
                                            if (matches and
                                                wanted == info.id)
                                            {
                                                const column_list: *const std.ArrayListUnmanaged(Element) =
                                                    &self.lists[field_index];
                                                const bytes: [*]const u8 = @ptrCast(column_list.items.ptr);
                                                return bytes[0 .. column_list.items.len * @sizeOf(Element)];
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    return null;
                }
                /// Appends an empty row across all columns plus the reference.
                /// - `self` - storage to mutate.
                /// - `allocator` - funds row allocation.
                /// - `reference` - handle stored alongside the components.
                /// Returns `u32` - position of the new row.
                fn add(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    reference: *const EntityReference,
                ) !u32 {
                    const type_info = @typeInfo(Tuple).@"struct";
                    inline for (type_info.fields, 0..) |field, field_index| {
                        const column_list = &self.lists[field_index];
                        _ = field;
                        try column_list.append(allocator, undefined);
                    }
                    try self.refs.append(allocator, reference.*);
                    return @intCast(self.refs.items.len - 1);
                }
                /// Removes a row across all columns via swap with the last row.
                /// - `self` - storage to mutate.
                /// - `index` - row position to remove.
                /// Returns `?EntityReference` - relocated reference, or null when the last row was removed.
                fn remove(
                    self: *Self,
                    index: u32,
                ) ?EntityReference {
                    const previous_count: usize = self.refs.items.len;
                    if (index >= previous_count) {
                        return null;
                    }
                    const type_info = @typeInfo(Tuple).@"struct";
                    inline for (type_info.fields, 0..) |field, field_index| {
                        const column_list = &self.lists[field_index];
                        _ = field;
                        _ = column_list.swapRemove(index);
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
                    const type_info = @typeInfo(Tuple).@"struct";
                    inline for (type_info.fields, 0..) |field, field_index| {
                        const column_list = &self.lists[field_index];
                        _ = field;
                        column_list.deinit(allocator);
                    }
                    self.refs.deinit(allocator);
                }
            };
        }
        /// Builds the concrete archetype type owning state and component storage.
        /// - `raw` - component type list; normalized internally.
        /// Returns `type` - archetype type with storage, descriptor and mutation helpers.
        pub fn CreateArchetype(comptime raw: []const type) type {
            const canonical: []const type =
                Ecs.GetComponentsTypes(raw);
            const type_list: [canonical.len]type = comptime block: {
                var scratch: [canonical.len]type = undefined;
                for (canonical, 0..) |item, type_index| {
                    scratch[type_index] = std.ArrayListUnmanaged(item);
                }
                break :block scratch;
            };
            const Tuple: type = std.meta.Tuple(&type_list);
            const Data: type = Ecs.ArchetypeData(Tuple);
            return struct {
                const Self = @This();
                /// Marks this type as an archetype for isArchetype checks.
                pub const kind = .archetype;
                /// Canonical component types held by this archetype.
                pub const components: []const type = canonical;
                /// Lazily assigned archetype id. Stable for the same type set.
                var id_storage: ?u32 = null;
                /// Component descriptors, one per canonical component.
                var infos: [canonical.len]*const Ecs.ComponentInfo =
                    undefined;
                /// Single cached runtime descriptor shared by all callers.
                var cache: ?Ecs.ArchetypeInfo = null;
                /// Owned SOA storage holding component columns and entity refs.
                var state: Data = .{
                    .lists = emptyTuple(),
                };
                /// Whether registration into the ECS registry has completed.
                var registered: bool = false;
                /// Builds a fully zeroed tuple of component lists.
                /// Returns `Tuple` - tuple with every list empty.
                fn emptyTuple() Tuple {
                    var blank: Tuple = undefined;
                    inline for (@typeInfo(Tuple).@"struct".fields, 0..) |_, field_index| {
                        blank[field_index] = .empty;
                    }
                    return blank;
                }
                const vtable = Ecs.VTable{
                    .add = struct {
                        fn addFunction(
                            erased: *anyopaque,
                            allocator: std.mem.Allocator,
                            reference: *const Ecs.EntityReference,
                        ) Ecs.EcsError!u32 {
                            const concrete: *Data =
                                @ptrCast(@alignCast(erased));
                            return concrete.add(allocator, reference);
                        }
                    }.addFunction,
                    .remove = struct {
                        fn removeFunction(
                            erased: *anyopaque,
                            index: u32,
                        ) ?Ecs.EntityReference {
                            const concrete: *Data =
                                @ptrCast(@alignCast(erased));
                            return concrete.remove(index);
                        }
                    }.removeFunction,
                    .count = struct {
                        fn countFunction(
                            erased: *const anyopaque,
                        ) u32 {
                            const concrete: *const Data =
                                @ptrCast(@alignCast(erased));
                            return concrete.count();
                        }
                    }.countFunction,
                    .entity = struct {
                        fn entityReferenceFunction(
                            erased: *const anyopaque,
                            index: u32,
                        ) ?Ecs.EntityReference {
                            const concrete: *const Data =
                                @ptrCast(@alignCast(erased));
                            return concrete.entity(index) catch null;
                        }
                    }.entityReferenceFunction,
                    .raw = struct {
                        fn getBytesFunction(
                            erased: *const anyopaque,
                            meta: *const Ecs.ComponentInfo,
                            index: u32,
                        ) ?[]const u8 {
                            const concrete: *const Data =
                                @ptrCast(@alignCast(erased));
                            return concrete.raw(
                                meta,
                                index,
                            );
                        }
                    }.getBytesFunction,
                    .raw_mut = struct {
                        fn getBytesMutableFunction(
                            erased: *anyopaque,
                            meta: *const Ecs.ComponentInfo,
                            index: u32,
                        ) ?[]u8 {
                            const concrete: *Data =
                                @ptrCast(@alignCast(erased));
                            return concrete.rawMut(
                                meta,
                                index,
                            );
                        }
                    }.getBytesMutableFunction,
                    .deinit = struct {
                        fn deinitFunction(
                            erased: *anyopaque,
                            allocator: std.mem.Allocator,
                        ) void {
                            const concrete: *Data =
                                @ptrCast(@alignCast(erased));
                            concrete.deinit(allocator);
                        }
                    }.deinitFunction,
                };
                /// Returns the lazily assigned archetype id.
                /// Returns `u32` - stable archetype id.
                pub fn id() u32 {
                    if (Self.id_storage == null) {
                        Self.id_storage =
                            Ecs.next_archetype_id;
                        Ecs.next_archetype_id += 1;
                    }
                    return Self.id_storage.?;
                }
                /// Returns a pointer to the owned component storage.
                /// Returns `*Data` - live SOA storage of this archetype.
                pub fn data() *Data {
                    return &Self.state;
                }

                /// Returns the cached runtime archetype descriptor.
                /// Returns `*ArchetypeInfo` - shared descriptor, built on first call.
                pub fn info() *Ecs.ArchetypeInfo {
                    _ = Self.id();
                    if (Self.cache == null) {
                        inline for (canonical, 0..) |item, type_index| {
                            Self.infos[type_index] =
                                Ecs.Component(item).info();
                        }
                        Self.cache = Ecs.ArchetypeInfo{
                            .id = Self.id_storage.?,
                            .components =
                                Self.infos[0..],
                            .superset_storage = .empty,
                            .data = @ptrCast(&Self.state),
                            .vtable = &Self.vtable,
                        };
                    }
                    return &Self.cache.?;
                }
                /// Registers this archetype: links components and maintains supersets.
                /// - `allocator` - funds registry, component and superset lists.
                /// Returns `*ArchetypeInfo` - registered runtime descriptor.
                pub fn register(
                    allocator: std.mem.Allocator,
                ) Ecs.EcsError!*Ecs.ArchetypeInfo {
                    if (Self.registered) {
                        return &Self.cache.?;
                    }
                    const handle: *Ecs.ArchetypeInfo =
                        Self.info();
                    inline for (canonical) |item| {
                        try Ecs.Component(item).attach(
                            allocator,
                            handle,
                        );
                    }
                    var present: bool = false;
                    for (Ecs.registry.items) |known| {
                        if (known == handle) {
                            present = true;
                            break;
                        }
                    }
                    if (!present) {
                        try Ecs.registry.append(
                            allocator,
                            handle,
                        );
                    }
                    for (Ecs.registry.items) |other| {
                        if (other == handle) {
                            continue;
                        }
                        if (covers(handle, other)) {
                            try Ecs.addSuperset(
                                allocator,
                                other,
                                handle,
                            );
                        }
                        if (covers(other, handle)) {
                            try Ecs.addSuperset(
                                allocator,
                                handle,
                                other,
                            );
                        }
                    }
                    Self.registered = true;
                    return handle;
                }
                /// Checks whether one archetype strictly contains another component set.
                /// - `super` - candidate superset.
                /// - `sub` - candidate subset.
                /// Returns `bool` - true when sub is a strict subset of super.
                fn covers(
                    super: *const Ecs.ArchetypeInfo,
                    sub: *const Ecs.ArchetypeInfo,
                ) bool {
                    for (sub.components) |need| {
                        var match: bool = false;
                        for (super.components) |have| {
                            if (have.id == need.id) {
                                match = true;
                                break;
                            }
                        }
                        if (!match) {
                            return false;
                        }
                    }
                    return super.components.len >
                        sub.components.len;
                }
                /// Resolves a single input to its underlying struct type.
                /// - `Single` - component, wrapper or single-component archetype.
                /// Returns `type` - unwrapped struct component type.
                fn unwrap(comptime Single: type) type {
                    if (Ecs.isComponent(Single)) {
                        return Single.ComponentType;
                    }
                    if (Ecs.isArchetype(Single)) {
                        if (Single.components.len != 1) {
                            @compileError("Single-component operation requires exactly one component type.");
                        }
                        return Single.components[0];
                    }
                    if (@typeInfo(Single) != .@"struct") {
                        @compileError("Component must be a struct type.");
                    }
                    return Single;
                }
                /// Adds one component, producing a derived archetype type.
                /// - `Single` - component, wrapper or single-component archetype.
                /// Returns `type` - archetype extended with the new component.
                pub fn add(comptime Single: type) type {
                    const Unwrapped: type = unwrap(Single);
                    const merged: []const type = comptime merge: {
                        var scratch: [canonical.len + 1]type = undefined;
                        for (canonical, 0..) |existing, existing_index| {
                            scratch[existing_index] = existing;
                        }
                        scratch[canonical.len] = Unwrapped;
                        const Merge = struct {
                            const table: [canonical.len + 1]type =
                                scratch;
                        };
                        break :merge Merge.table[0..];
                    };
                    return Ecs.Archetype(merged);
                }
                /// Adds several components at once, producing a derived archetype type.
                /// - `extra` - component types to add.
                /// Returns `type` - archetype extended with the new components.
                pub fn addMany(comptime extra: []const type) type {
                    const merged: []const type = comptime merge: {
                        var scratch: [canonical.len + extra.len]type =
                            undefined;
                        for (canonical, 0..) |existing, existing_index| {
                            scratch[existing_index] = existing;
                        }
                        for (extra, 0..) |item, item_index| {
                            scratch[canonical.len + item_index] =
                                item;
                        }
                        const Merge = struct {
                            const table: [canonical.len + extra.len]type =
                                scratch;
                        };
                        break :merge Merge.table[0..];
                    };
                    return Ecs.Archetype(merged);
                }
                /// Removes one component, producing a derived archetype type.
                /// - `Single` - component to remove. Must be present and not the last one.
                /// Returns `type` - archetype narrowed by the removed component.
                pub fn remove(comptime Single: type) type {
                    const Unwrapped: type = unwrap(Single);
                    comptime var found: ?usize = null;
                    inline for (canonical, 0..) |existing, existing_index| {
                        if (existing == Unwrapped) {
                            found = existing_index;
                        }
                    }
                    if (found == null) {
                        @compileError("Cannot remove a component that is not part of this archetype.");
                    }
                    if (canonical.len <= 1) {
                        @compileError("Archetype must keep at least one component after removal.");
                    }
                    const rest: []const type = comptime rest: {
                        var scratch: [canonical.len - 1]type = undefined;
                        var cursor: usize = 0;
                        for (canonical, 0..) |existing, existing_index| {
                            if (existing_index == found.?) {
                                continue;
                            }
                            scratch[cursor] = existing;
                            cursor += 1;
                        }
                        const Rest = struct {
                            const table: [canonical.len - 1]type =
                                scratch;
                        };
                        break :rest Rest.table[0..];
                    };
                    return Ecs.Archetype(rest);
                }
                /// Removes several components at once, producing a derived archetype type.
                /// - `removed` - component types to remove. Must leave at least one.
                /// Returns `type` - archetype narrowed by the removed components.
                pub fn removeMany(comptime removed: []const type) type {
                    const targets: []const type =
                        Ecs.GetComponentsTypes(removed);
                    for (targets) |target| {
                        var present: bool = false;
                        for (canonical) |existing| {
                            if (existing == target) {
                                present = true;
                                break;
                            }
                        }
                        if (!present) {
                            @compileError("Cannot remove a component that is not part of this archetype.");
                        }
                    }
                    const rest: []const type = comptime rest: {
                        var scratch: [canonical.len]type = undefined;
                        var cursor: usize = 0;
                        for (canonical) |existing| {
                            var skip: bool = false;
                            for (targets) |target| {
                                if (existing == target) {
                                    skip = true;
                                    break;
                                }
                            }
                            if (!skip) {
                                scratch[cursor] = existing;
                                cursor += 1;
                            }
                        }
                        if (cursor == 0) {
                            @compileError("Archetype must keep at least one component after removal.");
                        }
                        const Rest = struct {
                            const table: [canonical.len]type =
                                scratch;
                            const total: usize = cursor;
                        };
                        break :rest Rest.table[0..Rest.total];
                    };
                    return Ecs.Archetype(rest);
                }
            };
        }
        /// Releases every registry, tracked and entity list owned by the namespace.
        /// - `allocator` - allocator that funded all storage.
        pub fn deinit(allocator: std.mem.Allocator) void {
            for (Ecs.registry.items) |handle| {
                handle.vtable.deinit(
                    handle.data,
                    allocator,
                );
                handle.superset_storage.deinit(allocator);
            }
            for (Ecs.tracked.items) |entry| {
                entry.deinit(allocator);
            }
            Ecs.registry.deinit(allocator);
            Ecs.tracked.deinit(allocator);
            Ecs.entities.deinit(allocator);
            Ecs.free_ids.deinit(allocator);
        }
    };
}
/// Horizontal and vertical coordinate component used by tests.
const Pos = struct { horizontal_coordinate: i32, vertical_coordinate: i32 };
/// Horizontal and vertical speed component used by tests.
const Vel = struct { horizontal_speed: f32, vertical_speed: f32 };
/// Current health amount component used by tests.
const Health = struct { current_value: u32 };
test "component identifier is stable per type" {
    const Ecs = ECS(16, 16);
    const First = Ecs.Component(Pos);
    const Second = Ecs.Component(Pos);
    const Other = Ecs.Component(Vel);
    try std.testing.expect(First.id() == Second.id());
    try std.testing.expect(First.id() != Other.id());
    try std.testing.expect(Ecs.isComponent(First));
    try std.testing.expect(!Ecs.isArchetype(First));
}
test "archetype order does not matter" {
    const Ecs = ECS(16, 16);
    const Left = Ecs.Archetype(&[_]type{ Pos, Vel });
    const Right = Ecs.Archetype(&[_]type{ Vel, Pos });
    try std.testing.expect(Left == Right);
    try std.testing.expect(Ecs.isArchetype(Left));
    try std.testing.expect(!Ecs.isComponent(Left));
}
test "archetype data stores and returns components" {
    const Ecs = ECS(16, 16);
    const Single = Ecs.Archetype(&[_]type{Health});
    const data = Single.data();
    const allocator = std.testing.allocator;
    const sample = Ecs.EntityReference{ .id = 0, .gen = 0 };
    const index: u32 = try data.add(allocator, &sample);
    try std.testing.expect(index == 0);
    try std.testing.expect(data.count() == 1);
    const health_mut: *Health = try data.getMut(Health, 0);
    health_mut.current_value = 42;
    const health: *const Health = try data.get(Health, 0);
    try std.testing.expect(health.current_value == 42);
    data.deinit(allocator);
}
test "entity create destroy and slot reuse" {
    const Ecs = ECS(24, 24);
    const Pair = Ecs.Archetype(&[_]type{ Pos, Vel });
    const allocator = std.testing.allocator;
    const handle = try Pair.register(allocator);
    defer Ecs.deinit(allocator);
    const created = try Ecs.Entity.create(allocator, handle);
    try std.testing.expect(created.reference.exists());
    try std.testing.expect(created.reference.isAlive());
    try std.testing.expect(handle.count() == 1);
    const data = Pair.data();
    const pos: *Pos =
        try data.getMut(Pos, created.index);
    pos.horizontal_coordinate = 10;
    try created.reference.destroy(allocator);
    try std.testing.expect(created.reference.exists());
    try std.testing.expect(!created.reference.isAlive());
    try std.testing.expect(handle.count() == 0);
    try std.testing.expectError(
        Ecs.EcsError.EntityIsNotAlive,
        created.reference.destroy(allocator),
    );
    const recycled = try Ecs.Entity.create(allocator, handle);
    try std.testing.expect(recycled.reference.id ==
        created.reference.id);
    try std.testing.expect(recycled.reference.gen ==
        created.reference.gen +% 1);
    try std.testing.expect(recycled.reference.isAlive());
}
test "entity migrate copies shared components" {
    const Ecs = ECS(56, 56);
    const Source = Ecs.Archetype(&[_]type{ Pos, Vel });
    const Dest = Ecs.Archetype(&[_]type{ Pos, Health });
    const allocator = std.testing.allocator;
    const source_info = try Source.register(allocator);
    const dest_info = try Dest.register(allocator);
    defer Ecs.deinit(allocator);
    const created = try Ecs.Entity.create(allocator, source_info);
    const source_data = Source.data();
    (try source_data.getMut(Pos, 0)).horizontal_coordinate = 7;
    (try source_data.getMut(Vel, 0)).horizontal_speed = 1.5;
    const migrated =
        try created.reference.migrate(allocator, dest_info, true);
    try std.testing.expect(migrated.isAlive());
    try std.testing.expect(!created.reference.isAlive());
    try std.testing.expect(source_info.count() == 0);
    try std.testing.expect(dest_info.count() == 1);
    const dest_data = Dest.data();
    const moved: *const Pos =
        try dest_data.get(Pos, 0);
    try std.testing.expect(moved.horizontal_coordinate == 7);
}
test "archetype registration tracks supersets and component lists" {
    const Ecs = ECS(48, 48);
    const Small = Ecs.Archetype(&[_]type{Pos});
    const Big = Ecs.Archetype(&[_]type{ Pos, Vel });
    const allocator = std.testing.allocator;
    const small_info = try Small.register(allocator);
    const big_info = try Big.register(allocator);
    defer Ecs.deinit(allocator);
    const supersets = small_info.supersets();
    try std.testing.expect(supersets.count() == 1);
    try std.testing.expect(supersets.get(0).? == big_info);
    try std.testing.expect(big_info.supersets().count() == 0);
    const pos_info = Ecs.Component(Pos).info();
    try std.testing.expect(pos_info.archetypes().count() == 2);
    const vel_info = Ecs.Component(Vel).info();
    try std.testing.expect(vel_info.archetypes().count() == 1);
}
test "add and remove components change archetype type" {
    const Ecs = ECS(40, 40);
    const Base = Ecs.Archetype(&[_]type{Pos});
    const Wide = Base.add(Vel);
    const Expect = Ecs.Archetype(&[_]type{ Pos, Vel });
    try std.testing.expect(Wide == Expect);
    const Slim = Wide.remove(Vel);
    try std.testing.expect(Slim == Base);
    const MultiWide = Base.addMany(&[_]type{ Vel, Health });
    const MultiExpect =
        Ecs.Archetype(&[_]type{ Pos, Vel, Health });
    try std.testing.expect(MultiWide == MultiExpect);
    const MultiSlim = MultiWide.removeMany(&[_]type{ Health, Vel });
    try std.testing.expect(MultiSlim == Base);
}
