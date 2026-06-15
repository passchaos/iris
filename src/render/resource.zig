//! Runtime resource bookkeeping shared by renderer backends.
//!
//! The render graph describes lifetimes; this module owns the mutable pool that
//! turns those lifetimes into stable handles, reusable transient slots, and
//! cache entries that can survive across frames.
const std = @import("std");
const render_graph = @import("render_graph.zig");

pub const ResourceKind = render_graph.ResourceKind;

pub const ResourceHandle = struct {
    index: usize,
    /// Bumped every time a record slot is reused so stale handles cannot destroy
    /// or access a newer resource that happens to occupy the same index.
    generation: u32,
    kind: ResourceKind,
};

pub const ResourceDesc = struct {
    label: []const u8 = "",
    kind: ResourceKind,
    /// Transient resources represent graph-planned scratch storage. Their slot
    /// value identifies the logical alias set chosen by RenderGraph.
    transient: bool = false,
    slot: ?usize = null,
};

pub const ResourceDebugDump = struct {
    handle: ResourceHandle,
    label: []const u8,
    kind: ResourceKind,
    alive: bool,
    transient: bool,
    slot: ?usize = null,
};

pub const ResourcePoolStats = struct {
    records: usize = 0,
    alive: usize = 0,
    leaked: usize = 0,
    created: usize = 0,
    destroyed: usize = 0,
    reused_handles: usize = 0,
    transient_resources: usize = 0,
    transient_slots: usize = 0,
    texture_slots: usize = 0,
    buffer_slots: usize = 0,
};

pub const ResourceCacheStats = struct {
    entries: usize = 0,
    hits: usize = 0,
    misses: usize = 0,
    stale_rebuilds: usize = 0,
};

pub const ResourceCacheDebugDump = struct {
    key: []const u8,
    handle: ResourceHandle,
    valid: bool,
};

const ResourceRecord = struct {
    label: []u8 = &.{},
    kind: ResourceKind = .buffer,
    generation: u32 = 0,
    alive: bool = false,
    transient: bool = false,
    slot: ?usize = null,

    fn handle(self: ResourceRecord, index: usize) ResourceHandle {
        return .{ .index = index, .generation = self.generation, .kind = self.kind };
    }

    fn deinit(self: *ResourceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.label = &.{};
    }
};

const CacheEntry = struct {
    key: []u8,
    handle: ResourceHandle,

    fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.key = &.{};
    }
};

pub const ResourcePool = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(ResourceRecord) = .empty,
    free_indices: std.ArrayList(usize) = .empty,
    created: usize = 0,
    destroyed: usize = 0,
    reused_handles: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ResourcePool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResourcePool) void {
        for (self.records.items) |*record| {
            record.deinit(self.allocator);
        }
        self.records.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *ResourcePool, desc: ResourceDesc) !ResourceHandle {
        const label = try self.allocator.dupe(u8, desc.label);
        errdefer self.allocator.free(label);

        if (self.free_indices.pop()) |index| {
            var record = &self.records.items[index];
            // Reuse storage records without reusing handle identity. The index
            // stays stable for dense arrays, while the generation prevents ABA
            // style bugs in caches and delayed destroys.
            record.* = .{
                .label = label,
                .kind = desc.kind,
                .generation = record.generation +% 1,
                .alive = true,
                .transient = desc.transient,
                .slot = desc.slot,
            };
            self.created += 1;
            self.reused_handles += 1;
            return record.handle(index);
        }

        try self.records.append(self.allocator, .{
            .label = label,
            .kind = desc.kind,
            .generation = 1,
            .alive = true,
            .transient = desc.transient,
            .slot = desc.slot,
        });
        self.created += 1;
        return self.records.items[self.records.items.len - 1].handle(self.records.items.len - 1);
    }

    pub fn destroy(self: *ResourcePool, handle: ResourceHandle) !void {
        const record = try self.liveRecord(handle);
        record.deinit(self.allocator);
        record.alive = false;
        record.transient = false;
        record.slot = null;
        self.destroyed += 1;
        try self.free_indices.append(self.allocator, handle.index);
    }

    pub fn isValid(self: *const ResourcePool, handle: ResourceHandle) bool {
        if (handle.index >= self.records.items.len) return false;
        const record = self.records.items[handle.index];
        return record.alive and record.generation == handle.generation and record.kind == handle.kind;
    }

    pub fn debugDump(self: *const ResourcePool, allocator: std.mem.Allocator) !std.ArrayList(ResourceDebugDump) {
        var dumps = try std.ArrayList(ResourceDebugDump).initCapacity(allocator, self.records.items.len);
        errdefer dumps.deinit(allocator);
        for (self.records.items, 0..) |record, index| {
            dumps.appendAssumeCapacity(.{
                .handle = record.handle(index),
                .label = record.label,
                .kind = record.kind,
                .alive = record.alive,
                .transient = record.transient,
                .slot = record.slot,
            });
        }
        return dumps;
    }

    pub fn stats(self: *const ResourcePool) ResourcePoolStats {
        var out = ResourcePoolStats{
            .records = self.records.items.len,
            .created = self.created,
            .destroyed = self.destroyed,
            .reused_handles = self.reused_handles,
        };
        for (self.records.items) |record| {
            if (!record.alive) continue;
            out.alive += 1;
            out.leaked += 1;
            if (record.transient) {
                out.transient_resources += 1;
            }
        }
        out.texture_slots = self.countTransientSlotsForKind(.texture);
        out.buffer_slots = self.countTransientSlotsForKind(.buffer);
        out.transient_slots = out.texture_slots + out.buffer_slots;
        return out;
    }

    pub fn ensureTransientSlots(self: *ResourcePool, plan: []const render_graph.TransientAllocation) !ResourcePoolStats {
        for (plan) |allocation| {
            if (self.findTransientSlot(allocation.kind, allocation.slot) != null) continue;
            // One live pool resource backs each graph slot. Multiple graph
            // resources can map to the same slot, so duplicate allocations here
            // would erase the savings computed by the render graph.
            _ = try self.create(.{
                .label = switch (allocation.kind) {
                    .texture => "transient-texture-slot",
                    .buffer => "transient-buffer-slot",
                },
                .kind = allocation.kind,
                .transient = true,
                .slot = allocation.slot,
            });
        }
        return self.stats();
    }

    fn findTransientSlot(self: *const ResourcePool, kind: ResourceKind, slot: usize) ?ResourceHandle {
        for (self.records.items, 0..) |record, index| {
            if (record.alive and record.transient and record.kind == kind and record.slot == slot) {
                return record.handle(index);
            }
        }
        return null;
    }

    fn countTransientSlotsForKind(self: *const ResourcePool, kind: ResourceKind) usize {
        var count: usize = 0;
        for (self.records.items, 0..) |record, i| {
            if (!record.alive or !record.transient or record.kind != kind) continue;
            const slot = record.slot orelse continue;
            var seen = false;
            for (self.records.items[0..i]) |previous| {
                if (previous.alive and previous.transient and previous.kind == kind and previous.slot == slot) {
                    seen = true;
                    break;
                }
            }
            if (!seen) count += 1;
        }
        return count;
    }

    fn liveRecord(self: *ResourcePool, handle: ResourceHandle) !*ResourceRecord {
        if (handle.index >= self.records.items.len) return error.InvalidResourceHandle;
        const record = &self.records.items[handle.index];
        // Validate all identity fields, not just the index. Kind checking catches
        // accidental texture/buffer mixups, and generation checking catches stale
        // handles after a slot has been destroyed and reused.
        if (!record.alive or record.generation != handle.generation or record.kind != handle.kind) return error.InvalidResourceHandle;
        return record;
    }
};

pub const ResourceCache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CacheEntry) = .empty,
    hits: usize = 0,
    misses: usize = 0,
    stale_rebuilds: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ResourceCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResourceCache) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn getOrCreate(self: *ResourceCache, pool: *ResourcePool, key: []const u8, desc: ResourceDesc) !ResourceHandle {
        if (self.findEntry(key)) |entry| {
            if (pool.isValid(entry.handle)) {
                self.hits += 1;
                return entry.handle;
            }
            // Cache entries keep their semantic key but must rebuild if the
            // underlying pool handle went stale. This preserves stable lookups
            // across frame-to-frame resource churn without exposing dead handles.
            self.misses += 1;
            self.stale_rebuilds += 1;
            entry.handle = try pool.create(desc);
            return entry.handle;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const handle = try pool.create(desc);
        errdefer pool.destroy(handle) catch {};
        try self.entries.append(self.allocator, .{ .key = key_copy, .handle = handle });
        self.misses += 1;
        return handle;
    }

    pub fn invalidate(self: *ResourceCache, key: []const u8) bool {
        if (self.findEntryIndex(key)) |index| {
            var entry = self.entries.orderedRemove(index);
            entry.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn clear(self: *ResourceCache) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn stats(self: *const ResourceCache) ResourceCacheStats {
        return .{
            .entries = self.entries.items.len,
            .hits = self.hits,
            .misses = self.misses,
            .stale_rebuilds = self.stale_rebuilds,
        };
    }

    pub fn debugDump(self: *const ResourceCache, allocator: std.mem.Allocator, pool: *const ResourcePool) !std.ArrayList(ResourceCacheDebugDump) {
        var dumps = try std.ArrayList(ResourceCacheDebugDump).initCapacity(allocator, self.entries.items.len);
        errdefer dumps.deinit(allocator);
        for (self.entries.items) |entry| {
            dumps.appendAssumeCapacity(.{
                .key = entry.key,
                .handle = entry.handle,
                .valid = pool.isValid(entry.handle),
            });
        }
        return dumps;
    }

    fn findEntry(self: *ResourceCache, key: []const u8) ?*CacheEntry {
        if (self.findEntryIndex(key)) |index| return &self.entries.items[index];
        return null;
    }

    fn findEntryIndex(self: *const ResourceCache, key: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.key, key)) return index;
        }
        return null;
    }
};

test "resource pool validates handles and reuses destroyed slots" {
    const allocator = std.testing.allocator;
    var pool = ResourcePool.init(allocator);
    defer pool.deinit();

    const first = try pool.create(.{ .label = "color", .kind = .texture });
    try std.testing.expect(pool.isValid(first));
    try pool.destroy(first);
    try std.testing.expect(!pool.isValid(first));
    try std.testing.expectError(error.InvalidResourceHandle, pool.destroy(first));

    const second = try pool.create(.{ .label = "depth", .kind = .texture });
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expect(pool.isValid(second));

    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.records);
    try std.testing.expectEqual(@as(usize, 1), stats.alive);
    try std.testing.expectEqual(@as(usize, 2), stats.created);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 1), stats.reused_handles);
}

test "resource pool debug dump reports lifetime and leak state" {
    const allocator = std.testing.allocator;
    var pool = ResourcePool.init(allocator);
    defer pool.deinit();

    const color = try pool.create(.{ .label = "color", .kind = .texture });
    const scratch = try pool.create(.{ .label = "scratch", .kind = .buffer, .transient = true, .slot = 0 });
    try pool.destroy(color);

    var dumps = try pool.debugDump(allocator);
    defer dumps.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), dumps.items.len);
    try std.testing.expect(!dumps.items[color.index].alive);
    try std.testing.expect(dumps.items[scratch.index].alive);
    try std.testing.expect(dumps.items[scratch.index].transient);
    try std.testing.expectEqual(@as(?usize, 0), dumps.items[scratch.index].slot);

    const stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.leaked);
    try std.testing.expectEqual(@as(usize, 1), stats.transient_resources);
    try std.testing.expectEqual(@as(usize, 1), stats.buffer_slots);
}

test "resource pool creates transient slot resources from render graph plan" {
    const allocator = std.testing.allocator;
    var graph = render_graph.RenderGraph.init(allocator);
    defer graph.deinit();

    const texture_a = try graph.addResource(.{ .label = "texture-a", .kind = .texture });
    const texture_b = try graph.addResource(.{ .label = "texture-b", .kind = .texture });
    const buffer_a = try graph.addResource(.{ .label = "buffer-a", .kind = .buffer });
    const target = try graph.addResource(.{ .label = "target", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "write-a", .kind = .compute, .writes = &.{ texture_a, buffer_a } });
    _ = try graph.addPass(.{ .label = "read-a", .kind = .render, .reads = &.{ texture_a, buffer_a } });
    _ = try graph.addPass(.{ .label = "write-b", .kind = .compute, .writes = &.{texture_b} });
    _ = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{texture_b}, .writes = &.{target}, .side_effect = true });

    var plan = try graph.transientAllocationPlan(allocator);
    defer plan.deinit(allocator);

    var pool = ResourcePool.init(allocator);
    defer pool.deinit();
    const stats = try pool.ensureTransientSlots(plan.items);
    try std.testing.expectEqual(@as(usize, 2), stats.transient_slots);
    try std.testing.expectEqual(@as(usize, 1), stats.texture_slots);
    try std.testing.expectEqual(@as(usize, 1), stats.buffer_slots);
    try std.testing.expectEqual(stats.transient_slots, pool.stats().alive);

    const again = try pool.ensureTransientSlots(plan.items);
    try std.testing.expectEqual(stats.created, again.created);
}

test "resource cache reports hit miss and stale rebuilds" {
    const allocator = std.testing.allocator;
    var pool = ResourcePool.init(allocator);
    defer pool.deinit();
    var cache = ResourceCache.init(allocator);
    defer cache.deinit();

    const first = try cache.getOrCreate(&pool, "texture:button", .{ .label = "button", .kind = .texture });
    const second = try cache.getOrCreate(&pool, "texture:button", .{ .label = "button-new", .kind = .texture });
    try std.testing.expectEqual(first, second);

    var stats = cache.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.entries);
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 1), stats.misses);
    try std.testing.expectEqual(@as(usize, 0), stats.stale_rebuilds);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().created);

    try pool.destroy(first);
    const rebuilt = try cache.getOrCreate(&pool, "texture:button", .{ .label = "button-rebuilt", .kind = .texture });
    try std.testing.expect(rebuilt.generation != first.generation);
    try std.testing.expect(pool.isValid(rebuilt));

    stats = cache.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 2), stats.misses);
    try std.testing.expectEqual(@as(usize, 1), stats.stale_rebuilds);
    try std.testing.expectEqual(@as(usize, 2), pool.stats().created);
}

test "resource cache invalidates keys and dumps entry validity" {
    const allocator = std.testing.allocator;
    var pool = ResourcePool.init(allocator);
    defer pool.deinit();
    var cache = ResourceCache.init(allocator);
    defer cache.deinit();

    const color = try cache.getOrCreate(&pool, "color", .{ .label = "color", .kind = .texture });
    const vertices = try cache.getOrCreate(&pool, "vertices", .{ .label = "vertices", .kind = .buffer });
    try pool.destroy(vertices);

    var dumps = try cache.debugDump(allocator, &pool);
    defer dumps.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), dumps.items.len);
    var saw_color = false;
    var saw_stale_vertices = false;
    for (dumps.items) |entry| {
        if (std.mem.eql(u8, entry.key, "color")) {
            saw_color = true;
            try std.testing.expect(entry.valid);
            try std.testing.expectEqual(color, entry.handle);
        } else if (std.mem.eql(u8, entry.key, "vertices")) {
            saw_stale_vertices = true;
            try std.testing.expect(!entry.valid);
        }
    }
    try std.testing.expect(saw_color);
    try std.testing.expect(saw_stale_vertices);

    try std.testing.expect(cache.invalidate("vertices"));
    try std.testing.expect(!cache.invalidate("missing"));
    try std.testing.expectEqual(@as(usize, 1), cache.stats().entries);
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.stats().entries);
}
