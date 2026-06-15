//! Lightweight render graph analysis for queued GPU work.
//!
//! This module does not execute passes. It records resource/pass relationships
//! and derives the information that backends need before execution: which passes
//! are live, which transient resources can share storage, and which access
//! hazards must be synchronized by a real GPU backend.
const std = @import("std");

pub const ResourceHandle = struct {
    index: usize,
};

pub const PassHandle = struct {
    index: usize,
};

pub const ResourceKind = enum {
    buffer,
    texture,
};

pub const PassKind = enum {
    render,
    compute,
    copy,
    debug,
};

pub const AccessKind = enum {
    read,
    write,
};

pub const ResourceDesc = struct {
    label: []const u8 = "",
    kind: ResourceKind,
    /// Transient resources are owned by the graph and may be mapped onto a
    /// reusable pool slot when their lifetimes do not overlap.
    transient: bool = true,
    /// External resources represent caller-owned targets such as swapchains.
    /// They are roots for liveness because visible output depends on them.
    external: bool = false,
};

pub const PassDesc = struct {
    label: []const u8 = "",
    kind: PassKind,
    reads: []const ResourceHandle = &.{},
    writes: []const ResourceHandle = &.{},
    /// Side-effect passes remain live even when they do not write an external
    /// resource directly. This covers presentation, readback, profiling, and
    /// debugging hooks.
    side_effect: bool = false,
};

pub const ResourceAccess = struct {
    resource: ResourceHandle,
    access: AccessKind,
};

pub const ResourceDebugDump = struct {
    label: []const u8,
    kind: ResourceKind,
    transient: bool,
    external: bool,
    first_pass: ?usize = null,
    last_pass: ?usize = null,
    readers: usize = 0,
    writers: usize = 0,
};

pub const PassDebugDump = struct {
    label: []const u8,
    kind: PassKind,
    reads: usize = 0,
    writes: usize = 0,
    culled: bool = false,
};

pub const PassAccessDebugDump = struct {
    pass_label: []const u8,
    pass_kind: PassKind,
    pass_index: usize,
    resource_label: []const u8,
    resource_kind: ResourceKind,
    resource_index: usize,
    access: AccessKind,
    culled: bool = false,
};

pub const ReusePair = struct {
    first: ResourceHandle,
    second: ResourceHandle,
};

pub const TransientAllocation = struct {
    resource: ResourceHandle,
    kind: ResourceKind,
    slot: usize,
    first_pass: usize,
    last_pass: usize,
};

pub const TransientPoolStats = struct {
    resources: usize = 0,
    slots: usize = 0,
    allocation_savings: usize = 0,
    texture_resources: usize = 0,
    texture_slots: usize = 0,
    texture_allocation_savings: usize = 0,
    buffer_resources: usize = 0,
    buffer_slots: usize = 0,
    buffer_allocation_savings: usize = 0,
};

pub const HazardKind = enum {
    read_after_read,
    read_after_write,
    write_after_read,
    write_after_write,
};

pub const Hazard = struct {
    resource: ResourceHandle,
    previous_pass: PassHandle,
    next_pass: PassHandle,
    previous_access: AccessKind,
    next_access: AccessKind,
    kind: HazardKind,
};

pub const RenderGraphDebugDump = struct {
    resources: usize = 0,
    passes: usize = 0,
    active_passes: usize = 0,
    culled_passes: usize = 0,
    edges: usize = 0,
    read_edges: usize = 0,
    write_edges: usize = 0,
    transient_resources: usize = 0,
    external_resources: usize = 0,
    reusable_pairs: usize = 0,
    transient_slots: usize = 0,
    transient_slot_savings: usize = 0,
    transient_texture_slots: usize = 0,
    transient_buffer_slots: usize = 0,
    hazards: usize = 0,
    read_after_write_hazards: usize = 0,
    write_after_read_hazards: usize = 0,
    write_after_write_hazards: usize = 0,
};

const Resource = struct {
    label: []u8,
    kind: ResourceKind,
    transient: bool,
    external: bool,
};

const Pass = struct {
    label: []u8,
    kind: PassKind,
    accesses: std.ArrayList(ResourceAccess) = .empty,
    side_effect: bool,

    fn deinit(self: *Pass, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.accesses.deinit(allocator);
        self.* = undefined;
    }
};

pub const RenderGraph = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(Resource) = .empty,
    passes: std.ArrayList(Pass) = .empty,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RenderGraph) void {
        for (self.passes.items) |*pass| {
            pass.deinit(self.allocator);
        }
        self.passes.deinit(self.allocator);
        for (self.resources.items) |*resource| {
            self.allocator.free(resource.label);
        }
        self.resources.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addResource(self: *RenderGraph, desc: ResourceDesc) !ResourceHandle {
        if (desc.transient and desc.external) return error.InvalidResourceFlags;
        const label = try self.allocator.dupe(u8, desc.label);
        errdefer self.allocator.free(label);
        try self.resources.append(self.allocator, .{
            .label = label,
            .kind = desc.kind,
            .transient = desc.transient,
            .external = desc.external,
        });
        return .{ .index = self.resources.items.len - 1 };
    }

    pub fn addPass(self: *RenderGraph, desc: PassDesc) !PassHandle {
        for (desc.reads) |resource| try self.validateResource(resource);
        for (desc.writes) |resource| try self.validateResource(resource);

        const label = try self.allocator.dupe(u8, desc.label);
        errdefer self.allocator.free(label);

        var pass = Pass{
            .label = label,
            .kind = desc.kind,
            .side_effect = desc.side_effect,
        };
        errdefer pass.deinit(self.allocator);
        try pass.accesses.ensureTotalCapacity(self.allocator, desc.reads.len + desc.writes.len);
        for (desc.reads) |resource| {
            pass.accesses.appendAssumeCapacity(.{ .resource = resource, .access = .read });
        }
        for (desc.writes) |resource| {
            pass.accesses.appendAssumeCapacity(.{ .resource = resource, .access = .write });
        }

        try self.passes.append(self.allocator, pass);
        return .{ .index = self.passes.items.len - 1 };
    }

    pub fn resourceDebugDump(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(ResourceDebugDump) {
        var dumps = try std.ArrayList(ResourceDebugDump).initCapacity(allocator, self.resources.items.len);
        errdefer dumps.deinit(allocator);
        for (self.resources.items) |resource| {
            dumps.appendAssumeCapacity(.{
                .label = resource.label,
                .kind = resource.kind,
                .transient = resource.transient,
                .external = resource.external,
            });
        }

        for (self.passes.items, 0..) |pass, pass_index| {
            for (pass.accesses.items) |access| {
                const dump = &dumps.items[access.resource.index];
                dump.first_pass = if (dump.first_pass) |first| @min(first, pass_index) else pass_index;
                dump.last_pass = if (dump.last_pass) |last| @max(last, pass_index) else pass_index;
                switch (access.access) {
                    .read => dump.readers += 1,
                    .write => dump.writers += 1,
                }
            }
        }

        return dumps;
    }

    pub fn passDebugDump(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(PassDebugDump) {
        var live = try self.livePassMask(allocator);
        defer live.deinit(allocator);

        var dumps = try std.ArrayList(PassDebugDump).initCapacity(allocator, self.passes.items.len);
        errdefer dumps.deinit(allocator);
        for (self.passes.items, 0..) |pass, index| {
            var reads: usize = 0;
            var writes: usize = 0;
            for (pass.accesses.items) |access| {
                switch (access.access) {
                    .read => reads += 1,
                    .write => writes += 1,
                }
            }
            dumps.appendAssumeCapacity(.{
                .label = pass.label,
                .kind = pass.kind,
                .reads = reads,
                .writes = writes,
                .culled = !live.items[index],
            });
        }
        return dumps;
    }

    pub fn passAccessDebugDump(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(PassAccessDebugDump) {
        var live = try self.livePassMask(allocator);
        defer live.deinit(allocator);

        var count: usize = 0;
        for (self.passes.items) |pass| {
            count += pass.accesses.items.len;
        }

        var dumps = try std.ArrayList(PassAccessDebugDump).initCapacity(allocator, count);
        errdefer dumps.deinit(allocator);
        for (self.passes.items, 0..) |pass, pass_index| {
            for (pass.accesses.items) |access| {
                const resource = self.resources.items[access.resource.index];
                dumps.appendAssumeCapacity(.{
                    .pass_label = pass.label,
                    .pass_kind = pass.kind,
                    .pass_index = pass_index,
                    .resource_label = resource.label,
                    .resource_kind = resource.kind,
                    .resource_index = access.resource.index,
                    .access = access.access,
                    .culled = !live.items[pass_index],
                });
            }
        }
        return dumps;
    }

    pub fn reusableTransientPairs(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(ReusePair) {
        var resources = try self.resourceDebugDump(allocator);
        defer resources.deinit(allocator);

        // Pairing is intentionally conservative: only same-kind transient
        // resources with disjoint pass lifetimes are considered aliases. Size
        // and format checks belong in a backend-specific allocator that has the
        // concrete image/buffer descriptors.
        var pairs: std.ArrayList(ReusePair) = .empty;
        errdefer pairs.deinit(allocator);
        for (resources.items, 0..) |lhs, lhs_index| {
            if (!resourceCanReuse(lhs)) continue;
            for (resources.items[lhs_index + 1 ..], lhs_index + 1..) |rhs, rhs_index| {
                if (!resourceCanReuse(rhs)) continue;
                if (lhs.kind != rhs.kind) continue;
                if (lifetimesOverlap(lhs, rhs)) continue;
                try pairs.append(allocator, .{
                    .first = .{ .index = lhs_index },
                    .second = .{ .index = rhs_index },
                });
            }
        }
        return pairs;
    }

    pub fn hazardDebugDump(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(Hazard) {
        var hazards: std.ArrayList(Hazard) = .empty;
        errdefer hazards.deinit(allocator);

        // A single forward scan is enough for diagnostics because each hazard is
        // expressed relative to the previous access to the same resource. A real
        // backend can lower these records into barriers or queue dependencies.
        var last_accesses = try std.ArrayList(?ResourceAccessState).initCapacity(allocator, self.resources.items.len);
        defer last_accesses.deinit(allocator);
        try last_accesses.appendNTimes(allocator, null, self.resources.items.len);

        for (self.passes.items, 0..) |pass, pass_index| {
            for (pass.accesses.items) |access| {
                if (last_accesses.items[access.resource.index]) |previous| {
                    try hazards.append(allocator, .{
                        .resource = access.resource,
                        .previous_pass = .{ .index = previous.pass_index },
                        .next_pass = .{ .index = pass_index },
                        .previous_access = previous.access,
                        .next_access = access.access,
                        .kind = hazardKind(previous.access, access.access),
                    });
                }
                last_accesses.items[access.resource.index] = .{
                    .pass_index = pass_index,
                    .access = access.access,
                };
            }
        }

        return hazards;
    }

    pub fn transientAllocationPlan(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(TransientAllocation) {
        var resources = try self.resourceDebugDump(allocator);
        defer resources.deinit(allocator);

        var plan: std.ArrayList(TransientAllocation) = .empty;
        errdefer plan.deinit(allocator);

        var slot_last_pass: std.ArrayList(usize) = .empty;
        defer slot_last_pass.deinit(allocator);
        var slot_kind: std.ArrayList(ResourceKind) = .empty;
        defer slot_kind.deinit(allocator);

        for (resources.items, 0..) |resource, resource_index| {
            if (!resourceCanReuse(resource)) continue;
            const first_pass = resource.first_pass.?;
            const last_pass = resource.last_pass.?;

            // First-fit interval packing keeps the plan deterministic and cheap.
            // Slots are separated by resource kind so texture and buffer memory
            // never alias, while non-overlapping intervals reuse the earliest
            // available slot.
            var slot: ?usize = null;
            for (slot_last_pass.items, 0..) |slot_last, slot_index| {
                if (slot_kind.items[slot_index] == resource.kind and slot_last < first_pass) {
                    slot = slot_index;
                    break;
                }
            }
            const chosen_slot = slot orelse blk: {
                try slot_kind.append(allocator, resource.kind);
                try slot_last_pass.append(allocator, 0);
                break :blk slot_last_pass.items.len - 1;
            };
            slot_last_pass.items[chosen_slot] = last_pass;
            try plan.append(allocator, .{
                .resource = .{ .index = resource_index },
                .kind = resource.kind,
                .slot = chosen_slot,
                .first_pass = first_pass,
                .last_pass = last_pass,
            });
        }

        return plan;
    }

    pub fn transientPoolStats(self: *const RenderGraph, allocator: std.mem.Allocator) !TransientPoolStats {
        var plan = try self.transientAllocationPlan(allocator);
        defer plan.deinit(allocator);
        return transientPoolStatsFromPlan(plan.items);
    }

    pub fn debugDump(self: *const RenderGraph, allocator: std.mem.Allocator) !RenderGraphDebugDump {
        var pass_dumps = try self.passDebugDump(allocator);
        defer pass_dumps.deinit(allocator);
        var resource_dumps = try self.resourceDebugDump(allocator);
        defer resource_dumps.deinit(allocator);
        var reusable = try self.reusableTransientPairs(allocator);
        defer reusable.deinit(allocator);
        var transient_plan = try self.transientAllocationPlan(allocator);
        defer transient_plan.deinit(allocator);
        const transient_pool = transientPoolStatsFromPlan(transient_plan.items);
        var hazards = try self.hazardDebugDump(allocator);
        defer hazards.deinit(allocator);

        var dump = RenderGraphDebugDump{
            .resources = self.resources.items.len,
            .passes = self.passes.items.len,
            .reusable_pairs = reusable.items.len,
            .transient_slots = transient_pool.slots,
            .transient_slot_savings = transient_pool.allocation_savings,
            .transient_texture_slots = transient_pool.texture_slots,
            .transient_buffer_slots = transient_pool.buffer_slots,
            .hazards = hazards.items.len,
        };
        for (pass_dumps.items) |pass| {
            if (pass.culled) {
                dump.culled_passes += 1;
            } else {
                dump.active_passes += 1;
            }
            dump.read_edges += pass.reads;
            dump.write_edges += pass.writes;
        }
        dump.edges = dump.read_edges + dump.write_edges;
        for (resource_dumps.items) |resource| {
            if (resource.transient) dump.transient_resources += 1;
            if (resource.external) dump.external_resources += 1;
        }
        for (hazards.items) |hazard| {
            switch (hazard.kind) {
                .read_after_read => {},
                .read_after_write => dump.read_after_write_hazards += 1,
                .write_after_read => dump.write_after_read_hazards += 1,
                .write_after_write => dump.write_after_write_hazards += 1,
            }
        }
        return dump;
    }

    fn livePassMask(self: *const RenderGraph, allocator: std.mem.Allocator) !std.ArrayList(bool) {
        var live = try std.ArrayList(bool).initCapacity(allocator, self.passes.items.len);
        errdefer live.deinit(allocator);
        try live.appendNTimes(allocator, false, self.passes.items.len);

        var required_resources: std.ArrayList(bool) = .empty;
        defer required_resources.deinit(allocator);
        try required_resources.appendNTimes(allocator, false, self.resources.items.len);
        for (self.resources.items, 0..) |resource, index| {
            required_resources.items[index] = resource.external;
        }

        // Work backward from externally visible resources. A pass becomes live
        // if it writes data that is currently required, then its reads become
        // required for earlier passes. Writes satisfy the requirement for that
        // resource, which lets overwritten intermediate results be culled.
        var pass_index = self.passes.items.len;
        while (pass_index > 0) {
            pass_index -= 1;
            const pass = &self.passes.items[pass_index];
            var needed = pass.side_effect;
            for (pass.accesses.items) |access| {
                if (access.access == .write and required_resources.items[access.resource.index]) needed = true;
            }
            if (!needed) continue;

            live.items[pass_index] = true;
            for (pass.accesses.items) |access| {
                switch (access.access) {
                    .read => required_resources.items[access.resource.index] = true,
                    .write => required_resources.items[access.resource.index] = false,
                }
            }
        }
        return live;
    }

    fn validateResource(self: *const RenderGraph, handle: ResourceHandle) !void {
        if (handle.index >= self.resources.items.len) return error.InvalidResourceHandle;
    }
};

const ResourceAccessState = struct {
    pass_index: usize,
    access: AccessKind,
};

fn resourceCanReuse(resource: ResourceDebugDump) bool {
    return resource.transient and !resource.external and resource.first_pass != null and resource.last_pass != null;
}

fn lifetimesOverlap(lhs: ResourceDebugDump, rhs: ResourceDebugDump) bool {
    const lhs_first = lhs.first_pass.?;
    const lhs_last = lhs.last_pass.?;
    const rhs_first = rhs.first_pass.?;
    const rhs_last = rhs.last_pass.?;
    return lhs_first <= rhs_last and rhs_first <= lhs_last;
}

fn countTransientSlots(plan: []const TransientAllocation) usize {
    var count: usize = 0;
    for (plan) |allocation| {
        count = @max(count, allocation.slot + 1);
    }
    return count;
}

fn transientPoolStatsFromPlan(plan: []const TransientAllocation) TransientPoolStats {
    var stats = TransientPoolStats{
        .resources = plan.len,
    };
    for (plan) |allocation| {
        switch (allocation.kind) {
            .texture => {
                stats.texture_resources += 1;
            },
            .buffer => {
                stats.buffer_resources += 1;
            },
        }
    }
    stats.texture_slots = countTransientSlotsForKind(plan, .texture);
    stats.buffer_slots = countTransientSlotsForKind(plan, .buffer);
    stats.slots = stats.texture_slots + stats.buffer_slots;
    stats.allocation_savings = if (stats.resources > stats.slots) stats.resources - stats.slots else 0;
    stats.texture_allocation_savings = if (stats.texture_resources > stats.texture_slots) stats.texture_resources - stats.texture_slots else 0;
    stats.buffer_allocation_savings = if (stats.buffer_resources > stats.buffer_slots) stats.buffer_resources - stats.buffer_slots else 0;
    return stats;
}

fn countTransientSlotsForKind(plan: []const TransientAllocation, kind: ResourceKind) usize {
    var count: usize = 0;
    for (plan, 0..) |allocation, i| {
        if (allocation.kind != kind) continue;
        var seen = false;
        for (plan[0..i]) |previous| {
            if (previous.kind == kind and previous.slot == allocation.slot) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

fn hazardKind(previous: AccessKind, next: AccessKind) HazardKind {
    return switch (previous) {
        .read => switch (next) {
            .read => .read_after_read,
            .write => .write_after_read,
        },
        .write => switch (next) {
            .read => .read_after_write,
            .write => .write_after_write,
        },
    };
}

test "render graph records pass/resource dependencies and debug dump" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const vertex_buffer = try graph.addResource(.{ .label = "vertices", .kind = .buffer });
    const color = try graph.addResource(.{ .label = "color", .kind = .texture });
    const swapchain = try graph.addResource(.{ .label = "swapchain", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "geometry", .kind = .render, .reads = &.{vertex_buffer}, .writes = &.{color} });
    _ = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{color}, .writes = &.{swapchain}, .side_effect = true });

    var resources = try graph.resourceDebugDump(allocator);
    defer resources.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), resources.items.len);
    try std.testing.expectEqualStrings("vertices", resources.items[vertex_buffer.index].label);
    try std.testing.expectEqual(@as(usize, 1), resources.items[color.index].readers);
    try std.testing.expectEqual(@as(usize, 1), resources.items[color.index].writers);
    try std.testing.expectEqual(@as(?usize, 0), resources.items[color.index].first_pass);
    try std.testing.expectEqual(@as(?usize, 1), resources.items[color.index].last_pass);

    var passes = try graph.passDebugDump(allocator);
    defer passes.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), passes.items.len);
    try std.testing.expect(!passes.items[0].culled);
    try std.testing.expect(!passes.items[1].culled);

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(@as(usize, 3), dump.resources);
    try std.testing.expectEqual(@as(usize, 2), dump.passes);
    try std.testing.expectEqual(@as(usize, 2), dump.active_passes);
    try std.testing.expectEqual(@as(usize, 0), dump.culled_passes);
    try std.testing.expectEqual(@as(usize, 4), dump.edges);
    try std.testing.expectEqual(@as(usize, 2), dump.transient_resources);
    try std.testing.expectEqual(@as(usize, 1), dump.external_resources);

    var accesses = try graph.passAccessDebugDump(allocator);
    defer accesses.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), accesses.items.len);
    try std.testing.expectEqualStrings("geometry", accesses.items[0].pass_label);
    try std.testing.expectEqualStrings("vertices", accesses.items[0].resource_label);
    try std.testing.expectEqual(AccessKind.read, accesses.items[0].access);
    try std.testing.expectEqualStrings("color", accesses.items[1].resource_label);
    try std.testing.expectEqual(AccessKind.write, accesses.items[1].access);
    try std.testing.expectEqualStrings("present", accesses.items[3].pass_label);
    try std.testing.expect(!accesses.items[3].culled);
}

test "render graph culls unused passes but preserves side effects" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const scratch = try graph.addResource(.{ .label = "scratch", .kind = .texture });
    const visible = try graph.addResource(.{ .label = "visible", .kind = .texture });
    const target = try graph.addResource(.{ .label = "target", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "unused", .kind = .compute, .writes = &.{scratch} });
    _ = try graph.addPass(.{ .label = "visible", .kind = .render, .writes = &.{visible} });
    _ = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{visible}, .writes = &.{target}, .side_effect = true });

    var passes = try graph.passDebugDump(allocator);
    defer passes.deinit(allocator);
    try std.testing.expect(passes.items[0].culled);
    try std.testing.expect(!passes.items[1].culled);
    try std.testing.expect(!passes.items[2].culled);

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(@as(usize, 2), dump.active_passes);
    try std.testing.expectEqual(@as(usize, 1), dump.culled_passes);

    var accesses = try graph.passAccessDebugDump(allocator);
    defer accesses.deinit(allocator);
    var saw_culled = false;
    for (accesses.items) |access| {
        if (std.mem.eql(u8, access.pass_label, "unused")) {
            saw_culled = access.culled;
            try std.testing.expectEqual(AccessKind.write, access.access);
        }
    }
    try std.testing.expect(saw_culled);
}

test "render graph reports non-overlapping transient resources as reusable" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const a = try graph.addResource(.{ .label = "a", .kind = .texture });
    const b = try graph.addResource(.{ .label = "b", .kind = .texture });
    const target = try graph.addResource(.{ .label = "target", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "write-a", .kind = .compute, .writes = &.{a}, .side_effect = true });
    _ = try graph.addPass(.{ .label = "write-b", .kind = .compute, .writes = &.{b} });
    _ = try graph.addPass(.{ .label = "present-b", .kind = .copy, .reads = &.{b}, .writes = &.{target}, .side_effect = true });

    var pairs = try graph.reusableTransientPairs(allocator);
    defer pairs.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), pairs.items.len);
    try std.testing.expectEqual(a.index, pairs.items[0].first.index);
    try std.testing.expectEqual(b.index, pairs.items[0].second.index);

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(@as(usize, 1), dump.reusable_pairs);
}

test "render graph builds transient allocation slots by lifetime and kind" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const texture_a = try graph.addResource(.{ .label = "texture-a", .kind = .texture });
    const texture_b = try graph.addResource(.{ .label = "texture-b", .kind = .texture });
    const texture_c = try graph.addResource(.{ .label = "texture-c", .kind = .texture });
    const buffer_a = try graph.addResource(.{ .label = "buffer-a", .kind = .buffer });
    const target = try graph.addResource(.{ .label = "target", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "write-a", .kind = .compute, .writes = &.{ texture_a, buffer_a } });
    _ = try graph.addPass(.{ .label = "read-a-write-c", .kind = .render, .reads = &.{texture_a}, .writes = &.{texture_c} });
    _ = try graph.addPass(.{ .label = "write-b", .kind = .compute, .writes = &.{texture_b} });
    _ = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{texture_b}, .writes = &.{target}, .side_effect = true });

    var plan = try graph.transientAllocationPlan(allocator);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), plan.items.len);

    var slot_texture_a: ?usize = null;
    var slot_texture_b: ?usize = null;
    var slot_texture_c: ?usize = null;
    var slot_buffer_a: ?usize = null;
    for (plan.items) |allocation| {
        if (allocation.resource.index == texture_a.index) {
            slot_texture_a = allocation.slot;
            try std.testing.expectEqual(@as(usize, 0), allocation.first_pass);
            try std.testing.expectEqual(@as(usize, 1), allocation.last_pass);
        } else if (allocation.resource.index == texture_b.index) {
            slot_texture_b = allocation.slot;
            try std.testing.expectEqual(@as(usize, 2), allocation.first_pass);
            try std.testing.expectEqual(@as(usize, 3), allocation.last_pass);
        } else if (allocation.resource.index == texture_c.index) {
            slot_texture_c = allocation.slot;
            try std.testing.expectEqual(@as(usize, 1), allocation.first_pass);
            try std.testing.expectEqual(@as(usize, 1), allocation.last_pass);
        } else if (allocation.resource.index == buffer_a.index) {
            slot_buffer_a = allocation.slot;
            try std.testing.expectEqual(ResourceKind.buffer, allocation.kind);
        }
    }

    try std.testing.expect(slot_texture_a != null);
    try std.testing.expect(slot_texture_b != null);
    try std.testing.expect(slot_texture_c != null);
    try std.testing.expect(slot_buffer_a != null);
    try std.testing.expectEqual(slot_texture_a.?, slot_texture_b.?);
    try std.testing.expect(slot_texture_c.? != slot_texture_a.?);
    try std.testing.expect(slot_buffer_a.? != slot_texture_a.?);

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(@as(usize, 3), dump.transient_slots);
    try std.testing.expectEqual(@as(usize, 1), dump.transient_slot_savings);
    try std.testing.expectEqual(@as(usize, 2), dump.transient_texture_slots);
    try std.testing.expectEqual(@as(usize, 1), dump.transient_buffer_slots);
}

test "render graph summarizes transient pool stats by resource kind" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const texture_a = try graph.addResource(.{ .label = "texture-a", .kind = .texture });
    const texture_b = try graph.addResource(.{ .label = "texture-b", .kind = .texture });
    const texture_c = try graph.addResource(.{ .label = "texture-c", .kind = .texture });
    const buffer_a = try graph.addResource(.{ .label = "buffer-a", .kind = .buffer });
    const buffer_b = try graph.addResource(.{ .label = "buffer-b", .kind = .buffer });
    const target = try graph.addResource(.{ .label = "target", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "write-a", .kind = .compute, .writes = &.{ texture_a, buffer_a } });
    _ = try graph.addPass(.{ .label = "read-a", .kind = .render, .reads = &.{ texture_a, buffer_a } });
    _ = try graph.addPass(.{ .label = "write-b", .kind = .compute, .writes = &.{ texture_b, buffer_b } });
    _ = try graph.addPass(.{ .label = "write-c", .kind = .compute, .writes = &.{texture_c} });
    _ = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{ texture_b, texture_c }, .writes = &.{target}, .side_effect = true });

    const stats = try graph.transientPoolStats(allocator);
    try std.testing.expectEqual(@as(usize, 5), stats.resources);
    try std.testing.expectEqual(@as(usize, 3), stats.slots);
    try std.testing.expectEqual(@as(usize, 2), stats.allocation_savings);
    try std.testing.expectEqual(@as(usize, 3), stats.texture_resources);
    try std.testing.expectEqual(@as(usize, 2), stats.texture_slots);
    try std.testing.expectEqual(@as(usize, 1), stats.texture_allocation_savings);
    try std.testing.expectEqual(@as(usize, 2), stats.buffer_resources);
    try std.testing.expectEqual(@as(usize, 1), stats.buffer_slots);
    try std.testing.expectEqual(@as(usize, 1), stats.buffer_allocation_savings);

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(stats.slots, dump.transient_slots);
    try std.testing.expectEqual(stats.allocation_savings, dump.transient_slot_savings);
    try std.testing.expectEqual(stats.texture_slots, dump.transient_texture_slots);
    try std.testing.expectEqual(stats.buffer_slots, dump.transient_buffer_slots);
}

test "render graph reports read write hazards between adjacent accesses" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    const color = try graph.addResource(.{ .label = "color", .kind = .texture });
    const target = try graph.addResource(.{ .label = "target", .kind = .texture, .transient = false, .external = true });

    _ = try graph.addPass(.{ .label = "write-a", .kind = .render, .writes = &.{color} });
    _ = try graph.addPass(.{ .label = "read-a", .kind = .compute, .reads = &.{color} });
    _ = try graph.addPass(.{ .label = "read-b", .kind = .debug, .reads = &.{color}, .side_effect = true });
    _ = try graph.addPass(.{ .label = "write-b", .kind = .render, .writes = &.{color} });
    _ = try graph.addPass(.{ .label = "write-c", .kind = .render, .writes = &.{color} });
    _ = try graph.addPass(.{ .label = "present", .kind = .copy, .reads = &.{color}, .writes = &.{target}, .side_effect = true });

    var hazards = try graph.hazardDebugDump(allocator);
    defer hazards.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), hazards.items.len);
    try std.testing.expectEqual(HazardKind.read_after_write, hazards.items[0].kind);
    try std.testing.expectEqual(HazardKind.read_after_read, hazards.items[1].kind);
    try std.testing.expectEqual(HazardKind.write_after_read, hazards.items[2].kind);
    try std.testing.expectEqual(HazardKind.write_after_write, hazards.items[3].kind);
    try std.testing.expectEqual(HazardKind.read_after_write, hazards.items[4].kind);
    try std.testing.expectEqual(color.index, hazards.items[0].resource.index);
    try std.testing.expectEqual(@as(usize, 0), hazards.items[0].previous_pass.index);
    try std.testing.expectEqual(@as(usize, 1), hazards.items[0].next_pass.index);

    const dump = try graph.debugDump(allocator);
    try std.testing.expectEqual(@as(usize, 5), dump.hazards);
    try std.testing.expectEqual(@as(usize, 2), dump.read_after_write_hazards);
    try std.testing.expectEqual(@as(usize, 1), dump.write_after_read_hazards);
    try std.testing.expectEqual(@as(usize, 1), dump.write_after_write_hazards);
}

test "render graph rejects invalid handles and resource flags" {
    const allocator = std.testing.allocator;
    var graph = RenderGraph.init(allocator);
    defer graph.deinit();

    try std.testing.expectError(error.InvalidResourceFlags, graph.addResource(.{ .label = "bad", .kind = .texture, .transient = true, .external = true }));
    try std.testing.expectError(error.InvalidResourceHandle, graph.addPass(.{ .label = "bad", .kind = .render, .reads = &.{.{ .index = 99 }} }));
}
