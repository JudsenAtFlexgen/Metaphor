const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const dev = utils.dev;
const Stream = utils.Stream;

const SC = @import("scalar.zig");
const SizeType = @import("tensor_components.zig").SizeType;
const SliceUnion = @import("tensor_components.zig").SliceUnion;

// debug stuff -- not particularly important

const debug = (builtin.mode == .Debug);

const SrcInfo = std.builtin.SourceLocation;

const MemoryTracker = struct {
    var creates: usize = 0;
    var destroys: usize = 0;
    var allocs: usize = 0;
    var frees: usize = 0;

    pub inline fn addCreate() void {
        if (comptime debug) MemoryTracker.creates += 1;
    }

    pub inline fn addDestroy() void {
        if (comptime debug) MemoryTracker.destroys += 1;
    }

    pub inline fn addAlloc() void {
        if (comptime debug) MemoryTracker.allocs += 1;
    }

    pub inline fn addFree() void {
        if (comptime debug) MemoryTracker.frees += 1;
    }
};

// this is used to default assign to node data. Probably not
// necessary and currently not used for anything important
inline fn sentinelPtr() *anyopaque {
    return @ptrFromInt(std.math.maxInt(usize));
}

// clean-up for slice casting from *anyopaque
inline fn castSlice(comptime T: type, ptr: *anyopaque, N: usize) []T {
    const _ptr: [*]T = @ptrCast(@alignCast(ptr));
    return _ptr[0..N];
}

// These functions will stand-in for devMalloc/Free - going with
// c-interface for sake of ease at the moment.

// Helper functions for allocator-lane cleanup

//////////////////////////////////////////
// here's where things actually start

// MAX_TYPES will be increased to 7 eventually
// MAX_NODES controls the size of the node stack
// MAX_DIMS is the highest rank a tensor can be

const MAX_TYPES: usize = 4;
const MAX_NODES = 1024;

pub const LaneAllocator = struct {
    const Self = @This();

    const AnyList = std.SinglyLinkedList(*anyopaque);

    const AnyNode = AnyList.Node;

    const TensorStackSize = 1024;

    const TensorStack = std.BoundedArray(struct { list: AnyList, len: usize }, TensorStackSize);

    //// data cache...
    scalar_lanes: [MAX_TYPES]AnyList,
    tensor_stack: TensorStack,

    // node cache...
    free_nodes: AnyList,
    node_buffer: [MAX_NODES]AnyNode,

    // Has to be called for the allocator to work... not quite init because
    // we can't return stack memory otherwise the nodes will point to invalid
    // addresses once we've exited the init function.

    pub fn setup(self: *Self) void {

        // this data structure gets created using an allocator.
        // due to that, we have to set the default field values.

        // n0 -> n1 -> n2 -> ... -> n_i -> null

        for (0..MAX_NODES - 1) |i| {
            self.node_buffer[i].next = &self.node_buffer[i + 1];
            self.node_buffer[i].data = sentinelPtr();
        }
        self.node_buffer[MAX_NODES - 1].next = null;
        self.node_buffer[MAX_NODES - 1].data = sentinelPtr();

        // l.first -> n0...
        self.free_nodes.first = &self.node_buffer[0];

        for (self.scalar_lanes[0..]) |*list| {
            list.first = null;
        }

        self.tensor_stack.len = 0;
    }

    pub fn deinit(self: *Self, stream: Stream) void {
        // all nodes reference the elements of
        // the free node buffer. Free anything
        // that hasn't been marked as sentinel
        for (self.node_buffer[0..]) |node| {
            if (node.data != sentinelPtr()) utils.free(node.data, stream);
        }
    }

    pub fn create(self: *Self, comptime T: type, stream: Stream) [*]T {
        const lane = comptime getTypeLane(T);

        if (self.scalar_lanes[lane].popFirst()) |node| {
            const ptr = self.releaseDataAndCacheNode(node);

            return @ptrCast(@alignCast(ptr));
        }

        return utils.create(T, stream);
    }

    pub fn destroy(self: *Self, scalar: anytype) void {
        var node = self.getFreeNode();

        node.data = @ptrCast(@alignCast(scalar));

        const lane = comptime getTypeLane(std.meta.Child(@TypeOf(scalar)));

        self.scalar_lanes[lane].prepend(node);
    }

    pub fn alloc(self: *Self, comptime T: type, N: usize, stream: Stream) []T {

        const byte_len = N * @sizeOf(T);

        const slice = self.tensor_stack.slice();

        for (0..slice.len) |i| {
            if (slice[i].len == byte_len) {
                // save our node and retrieve the slice
                if (slice[i].list.popFirst()) |node| {
                    const ptr = self.releaseDataAndCacheNode(node);
                    return castSlice(T, ptr, N);
                } else {
                    break;
                }
            }
        }
        return utils.alloc(T, N, stream);
    }

    pub fn free(self: *Self, tensor: anytype, stream: Stream) void {
        const node = self.getFreeNode();

        const T = std.meta.Child(@TypeOf(tensor));

        const byte_len = tensor.len * @sizeOf(T);

        node.data = tensor.ptr;

        const slice = self.tensor_stack.slice();

        for (0..slice.len) |i| {
            if (slice[i].len == byte_len) {
                return slice[i].list.prepend(node);
            }
        }

        // no tensor blocks were found that match the length
        self.tensor_stack.append(.{ .list = .{ .first = node }, .len = byte_len }) catch {
            utils.free(tensor, stream); // StackOverflow
        };
    }

    // load precache values for the tensor allocator to use
    pub fn precache(self: *Self, comptime T: type, size: usize, count: usize, stream: Stream) void {
        for (0..count) |_| {
            self.free(utils.alloc(T, size, stream), stream);
        }
    }

    pub fn used(self: *const Self) usize {
        var count: usize = 0;
        for (self.node_buffer[0..]) |node| {
            if (node.data != sentinelPtr()) count += 1;
        }
        return count;
    }

    ///////////////////////////////////////////
    // internal functions for the LaneAllocator

    // This is where types go to become lanes. Each type
    // has it's own lane in the current version.
    fn getTypeLane(comptime T: type) usize {
        return switch (T) {
            SC.q8 => 0,
            SC.r16 => 1,
            SC.r32 => 2,
            SC.r64 => 3,
            else => @compileError("Invalid type for LaneAllocator: " ++ @typeName(T)),
        };
    }

    inline fn getFreeNode(self: *Self) *AnyNode {
        const node = self.free_nodes.popFirst() orelse @panic("Node Buffer Exhausted");
        node.next = null;
        return node;
    }

    // we have to capture the data pointer before breaking the node's connection
    inline fn releaseDataAndCacheNode(self: *Self, node: *AnyNode) *anyopaque {
        const ptr = node.data;
        node.data = sentinelPtr();
        self.free_nodes.prepend(node);
        return ptr;
    }
};
