const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const kernels = @import("kernels.zig");
const invoke = @import("root.zig").invoke;

pub const UT = @import("utils.zig");
pub const SC = @import("scalar.zig");
pub const TC = @import("tensor_components.zig");
const LaneAllocator = @import("lane_allocator.zig").LaneAllocator;
const Stream = UT.Stream;
const StreamContext = UT.StreamContext;
const CG = @This();

const Child = UT.Child;

// for graph save and load functions
const loadTensorToGraph = @import("tensor_file.zig").loadTensorToGraph;
const saveTensorFromGraph = @import("tensor_file.zig").saveTensorFromGraph;

// implementation declarations
const SliceUnion = TC.SliceUnion;
const Strides = TC.Strides;
const Sizes = TC.Sizes;

pub const TensorClass = enum(u2) {
    inp = 0, // non-trainable, but can have gradients
    wgt = 1, // trainable and has gradients
    hid = 2, // TODO: change this to res for "result"? These are always the outcome of an operation.
};

pub const Tensor = struct {

    const Self = @This();
    
    ptr: *Graph,
    idx: usize,
    class: TensorClass,

    // shallow equality
    pub fn same(self: Tensor, other: Tensor) bool {
        return std.meta.eql(self, other);
    }
    pub fn data(self: Tensor) SliceUnion {
        return switch (self.class) {
            .hid => self.ptr.node_block.data.items[self.idx],
            else => self.ptr.leaf_block.data.items[self.idx],
        };
    }
    pub fn grad(self: Tensor) ?SliceUnion {
        return switch (self.class) {
            .hid => self.ptr.node_block.grad.items[self.idx],
            else => self.ptr.leaf_block.grad.items[self.idx],
        };
    }
    pub fn data_ptr(self: Tensor) *anyopaque {
        return self.data().opaque_ptr();
    }
    pub fn grad_ptr(self: Tensor) ?*anyopaque {
        return if (self.grad()) |grd| grd.opaque_ptr() else null;
    }
    pub fn sizes(self: Tensor) Sizes {
        return switch (self.class) {
            .hid => self.ptr.node_block.sizes.items[self.idx],
            else => self.ptr.leaf_block.sizes.items[self.idx],
        };
    }
    pub fn strides(self: Tensor) Strides {
        return switch (self.class) {
            .hid => self.ptr.node_block.strides.items[self.idx],
            else => self.ptr.leaf_block.strides.items[self.idx],
        };
    }
    pub fn stream(self: Tensor) StreamContext {
        return self.ptr.stream.context;
    }
    pub fn len(self: Tensor) usize {
        return self.data().len();
    }
    pub fn rank(self: Tensor) usize {
        return self.sizes().len;
    }
    pub fn detach(self: Tensor) void {
        if (self.class == .hid) self.ptr.set_attachment(self.idx, false);
    }
    pub fn free(self: Tensor) void {
        self.ptr.free_raw_tensor(self.data(), self.class, self.idx);
    }
    pub fn reverse(self: Tensor, cleanup: ReverseCleanup) void {
        if (self.grad() == null) {
            // if a loss hasn't been applied, this will be null
            enable_gradient(self);
            // derivative with respect to self is 1
            invoke(kernels.fill, dkey(self), .{ self.grad_ptr(), 1.0, self.len(), self.stream() });
        }
        if (self.class != .hid) return;
        
        self.ptr.reverse(self.idx, cleanup);
    }

    pub fn dtype(self: Tensor) SC.Tag {
        return self.data().dtype();
    }

    pub fn derive(self: Tensor, wrt: Tensor) ?Tensor {

        if (self.ptr.mode == .eval) 
            return null;

        if (self.same(wrt)) {
            const dx = wrt.ptr.tensor(.{ .class = .hid, .dtype = self.dtype(), .sizes = self.sizes() });
            invoke(kernels.fill, dkey(self), .{ dx.data_ptr(), 1.0, dx.len(), dx.stream() });
            return dx;
        }

        if (self.class != .hid)
            return null;

        if (self.ptr.node_block.ops.items[self.idx]) |op| {
            const datum = op.derive(wrt) orelse return null;

            if (datum == .scalar) { // constant valued tensor
                const dx = wrt.ptr.tensor(.{ .class = .hid, .dtype = self.dtype(), .sizes = self.sizes() });
                invoke(kernels.fill, dkey(self), .{ dx.data_ptr(), datum.scalar, dx.len(), dx.stream() });
                return dx;
            }

            return datum.tensor;
        }        

        return null;
    }
};

// non-public api for tensors
// to get their dispatch keys
pub fn dkey(self: Tensor) usize {
    const key: usize = @intFromEnum(self.dtype());
    std.debug.assert(key < 3);
    return key;
}

///////////////////////////////
//     Quantization Maps     //
///////////////////////////////

// TODO: Currently not used

const QuantizeMode = enum(u1) { sym = 0, asym = 1 };

const QuantizeParent = enum(u2) {
    r32 = @intFromEnum(SC.r32), 
    r64 = @intFromEnum(SC.r64),  
};

const QuantizeComponent = struct {
    /// Denotes symmetric vs asymmetric quantization.
    mode: QuantizeMode,
    /// Stores what the parent type of the quantization
    /// was to determine the dtype of a resulting tensor.
    /// This currently cannot be another q8 type.
    dtype: QuantizeParent,
    /// Floating point tensor to project quantized q8
    /// values back to higher precision floating point.
    /// Can be rank zero or higher. Higher rank values
    /// are often referred to as "values". 
    scale: Tensor,
    /// Adjusts result tensor value by a scaled minimum
    /// to guarentee that zero is within the range.
    /// Always null if mode is symmetric.
    zpoint: ?Tensor,

    pub fn target(self: *const QuantizeComponent) SC.Tag {
        return @enumFromInt(self.index());
    }
};

const QuantizeMap = std.AutoHashMap(usize, QuantizeComponent); 

///////////////////////////
//   Computation Graph   // 
///////////////////////////

const Mode = enum { train, eval };

pub const ReverseCleanup = enum { keep, free };

pub const GraphConfig = struct {
    stream: Stream,
    mode: Mode,
};

pub const Graph = struct {

    const LeafBlock = struct {
        data: ArrayList(SliceUnion),
        grad: ArrayList(?SliceUnion),
        sizes: ArrayList(Sizes),
        strides: ArrayList(Strides),
        classes: ArrayList(TensorClass),
        pub fn init(allocator: std.mem.Allocator, block_size: usize) !LeafBlock {
            return .{
                .data = try ArrayList(SliceUnion).initCapacity(allocator, block_size),
                .grad = try ArrayList(?SliceUnion).initCapacity(allocator, block_size),
                .sizes = try ArrayList(Sizes).initCapacity(allocator, block_size),
                .strides = try ArrayList(Strides).initCapacity(allocator, block_size),
                .classes = try ArrayList(TensorClass).initCapacity(allocator, block_size),
            };
        }
    };

    const NodeBlock = struct {
        ops: ArrayList(?OpInterface),
        data: ArrayList(SliceUnion),
        grad: ArrayList(?SliceUnion),
        sizes: ArrayList(Sizes),
        strides: ArrayList(Strides),
        deps: ArrayList(i32),
        attached: ArrayList(bool),
        pub fn init(allocator: std.mem.Allocator, block_size: usize) !NodeBlock {
            return .{
                .ops = try ArrayList(?OpInterface).initCapacity(allocator, block_size),
                .data = try ArrayList(SliceUnion).initCapacity(allocator, block_size),
                .grad = try ArrayList(?SliceUnion).initCapacity(allocator, block_size),
                .sizes = try ArrayList(Sizes).initCapacity(allocator, block_size),
                .strides = try ArrayList(Strides).initCapacity(allocator, block_size),
                .deps = try ArrayList(i32).initCapacity(allocator, block_size),
                .attached = try ArrayList(bool).initCapacity(allocator, block_size),
            };
        }
    };

    node_max: usize,
    leaf_max: usize,
    leaf_arena: std.heap.ArenaAllocator,
    node_arena: std.heap.ArenaAllocator,
    tensor_allocator: LaneAllocator,
    leaf_block: LeafBlock,
    node_block: NodeBlock,
    mode: Mode,
    stream: Stream,

    pub fn id(self: *const Graph) usize {
        return @intFromPtr(self);
    }

    // this function ensures the correct allocator
    // and size are passed to the designated block
    fn init_leaf_block(self: *Graph) LeafBlock {
        return LeafBlock.init(self.leaf_arena.allocator(), self.leaf_max) 
            catch @panic("Graph.init_leaf_block: Out of Memory");
    }

    // this function ensures the correct allocator
    // and size are passed to the designated block
    fn init_node_block(self: *Graph) NodeBlock {
        return NodeBlock.init(self.node_arena.allocator(), self.node_max) 
            catch @panic("Graph.init_node_block: Out of Memory");
    }

    pub fn init(config: GraphConfig) *Graph {
        const self = std.heap.c_allocator.create(Graph) 
            catch @panic("Graph.init: Out of Memory");
        self.stream = config.stream;
        self.leaf_max = 0;
        self.node_max = 0;
        self.leaf_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        self.node_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        self.leaf_block = self.init_leaf_block();
        self.node_block = self.init_node_block();
        self.tensor_allocator.setup();
        self.mode = config.mode;
        return self;
    }

    pub fn deinit(self: *Graph) void {
        // hand our memory back to the allocator
        self.reset(.node, .all);
        self.reset(.leaf, .all);

        // free our memory from the allocator
        self.tensor_allocator.deinit(self.stream);

        self.node_arena.deinit();
        self.leaf_arena.deinit();

        // this must always be last
        std.heap.c_allocator.destroy(self);
    }

    const ResetGroup = enum { node, leaf };

    const ResetComponent = enum { all, grd };

    // this function helps defragment the arenas and
    // preps the graph - called by reverse conditionally
    pub fn reset(self: *Graph, group: ResetGroup, component: ResetComponent) void {
        if (group == .leaf) {
            if (component == .grd) {
                for (self.leaf_block.grad.items, 0..) |opt, i| {
                    if (opt) |raw| self.free_raw_gradient(raw, .inp, i);
                }
            }
            if (component == .all) {
                // frees both data and grad
                for (self.leaf_block.data.items, 0..) |raw, i| {
                    if (0 < raw.len()) self.free_raw_tensor(raw, .inp, i);
                }
                // keep the max number of leaf_block created
                self.leaf_max = @max(self.leaf_max, self.leaf_block.data.items.len);

                // drop all of our data out of play
                _ = self.leaf_arena.reset(.retain_capacity);

                // reinstantiate the array lists
                self.leaf_block = self.init_leaf_block();
            }
        } else {
            if (component == .grd) {
                for (self.node_block.grad.items, 0..) |opt, i| {
                    if (opt) |raw| self.free_raw_gradient(raw, .hid, i);
                    self.node_block.deps.items[i] = 0;
                }
            }
            if (component == .all) {
                for (self.node_block.data.items, 0..) |raw, i| {
                    if (0 < raw.len()) self.free_raw_tensor(raw, .hid, i);
                }
                // keep the max number of leaf_block created
                self.node_max = @max(self.node_max, self.node_block.data.items.len);

                // drop all of our data out of play
                _ = self.node_arena.reset(.retain_capacity);

                // reinstantiate the array lists
                self.node_block = self.init_node_block();
            }
        }
    }

    // load precache data for the tensor allocator to use
    pub fn precache(self: *Graph, comptime T: type, size: usize, count: usize) void {
        self.tensor_allocator.precache(T, size, count, self.stream);
    }

    inline fn set_attachment(self: *Graph, idx: usize, state: bool) void {
        self.node_block.attached.items[idx] = state;
    }

    inline fn attached(self: *Graph, idx: usize) bool {
        return self.node_block.attached.items[idx];
    }

    fn tensor_from_components(
        self: *Graph,
        class: TensorClass,
        data: SliceUnion,
        sizes: Sizes,
        strides: Sizes,
    ) !Tensor {
        std.debug.assert(0 < sizes.len);
        std.debug.assert(0 < strides.len);

        if (class == .hid) {
            try self.node_block.data.append(data);
            try self.node_block.sizes.append(sizes);
            try self.node_block.strides.append(strides);
            try self.node_block.grad.append(null);
            try self.node_block.deps.append(0);
            try self.node_block.attached.append(true);
            try self.node_block.ops.append(null);
        } else {
            try self.leaf_block.data.append(data);
            try self.leaf_block.sizes.append(sizes);
            try self.leaf_block.strides.append(strides);
            try self.leaf_block.grad.append(null);
            try self.leaf_block.classes.append(class);
        }

        const idx = if (class == .hid) 
            self.node_block.data.items.len - 1 else
            self.leaf_block.data.items.len - 1;

        return .{
            .ptr = self,
            .idx = idx,
            .class = class,
        };
    }

    fn construct_tensor(
        self: *Graph,
        class: TensorClass,
        dtype: SC.Tag,
        sizes: Sizes, // fixed-length array
        allocator: std.mem.Allocator,
    ) Tensor {
        std.debug.assert(0 < sizes.len);

        const N = blk: {
            var n: usize = 1;
            for (sizes) |s| n *= s;
            break :blk n;
        };

        std.debug.assert(0 < N);

        const data: SliceUnion = switch (dtype) {
            .r16 => SliceUnion.init(self.tensor_allocator.alloc(SC.r16, N, self.stream)),
            .r32 => SliceUnion.init(self.tensor_allocator.alloc(SC.r32, N, self.stream)),
            .r64 => SliceUnion.init(self.tensor_allocator.alloc(SC.r64, N, self.stream)),
        };

        const _sizes = allocator.dupe(usize, sizes) 
            catch @panic("failed to duplicate sizes");

        const strides = allocator.alloc(usize, sizes.len) 
            catch @panic("failed to allocate strides");

        TC.compute_strides(_sizes, strides);

        return self.tensor_from_components(class, data, _sizes, strides) 
            catch @panic("Failed to add tensor from components.");
    }

    ////////////////////////////////////////////
    // public api for making leaf tensors

    pub fn tensor(
        self: *Graph,
        config: struct {
            class: TensorClass,
            dtype: SC.Tag,
            sizes: Sizes, 
        },
    ) Tensor {
            
        const allocator = switch (config.class) {
            .hid => self.node_arena.allocator(),
            else => self.leaf_arena.allocator(),
        };
        
        return self.construct_tensor(
            config.class,
            config.dtype,
            config.sizes,
            allocator
        );
    }

    fn free_gradient(
        self: *Graph,
        class: TensorClass,
        comptime data_type: type,
        idx: usize
    ) void {

        const grad_array = switch (class) {
            .hid => &self.node_block.grad,
            else => &self.leaf_block.grad,
        };

        if (grad_array.items[idx]) |grad| {
            self.tensor_allocator.free(grad.cast(data_type), self.stream);
            grad_array.items[idx] = null;
        }
    }

    // TODO: Consider moving this logic to the allocator instead
    fn free_raw_gradient(self: *Graph, raw: SliceUnion, class: TensorClass, idx: usize) void {
        switch (raw) {
            .r16 => self.free_gradient(class, SC.r16, idx),
            .r32 => self.free_gradient(class, SC.r32, idx),
            .r64 => self.free_gradient(class, SC.r64, idx),
        }
    }

    fn free_tensor(self: *Graph, class: TensorClass, comptime data_type: type, idx: usize) void {

        const data = if (class == .hid) 
            &self.node_block.data.items[idx] else
            &self.leaf_block.data.items[idx];

        if (data.len() == 0)
            return;

        const field = comptime SC.name(data_type);

        self.tensor_allocator.free(@field(data.*, field), self.stream);

        @field(data.*, field).len = 0;

        self.free_gradient(class, data_type, idx);
    }

    // TODO: Consider moving this logic to the allocator instead
    fn free_raw_tensor(self: *Graph, raw: SliceUnion, class: TensorClass, idx: usize) void {
        switch (raw) {
            .r16 => self.free_tensor(class, SC.r16, idx),
            .r32 => self.free_tensor(class, SC.r32, idx),
            .r64 => self.free_tensor(class, SC.r64, idx),
        }
    }

    fn reverse(self: *Graph, idx: usize, cleanup: ReverseCleanup) void {

        std.debug.assert(self.mode != .eval);

        const total = self.node_block.ops.items.len;

        if (total == 0) return;

        // Reversal works like a simple breadth-first traversal. For each
        // node, we call reverse (which populates the gradients of its
        // reverse children). If all the deps have been collected
        // for that child, the child is a .hid type (it was computed),
        // and it's attached, then we add it the node stack to be reverse.

        var node_stack = std.ArrayList(usize).initCapacity(self.node_arena.allocator(), idx + 1) 
            catch @panic("Graph.reverse: Out of Memory.");

        var free_stack: std.ArrayList(usize) = undefined;

        if (cleanup == .free) {
            free_stack = std.ArrayList(usize).initCapacity(self.node_arena.allocator(), idx + 1) 
                catch @panic("Graph.reverse: Out of Memory.");
        }

        defer {
            node_stack.deinit();
            if (cleanup == .free) {
                free_stack.deinit();
            }
        }

        // put parameter node on the top of the stack
        node_stack.appendAssumeCapacity(idx);

        while (node_stack.popOrNull()) |last| {

            const op: *OpInterface = &(self.node_block.ops.items[last] orelse continue);

            if (cleanup == .free)
                free_stack.append(last) catch @panic("Failed to append to free stack.");

            op.reverse();

            var itr = op.iterator();

            while (itr.next()) |*arg| {

                if (arg.* != .tensor)
                    continue;

                if (arg.tensor.class != .hid or arg.tensor.idx == last)
                    continue;

                if (!self.attached(arg.tensor.idx))
                    continue;

                if (adjust_deps(arg.tensor, -1) == 0)
                    node_stack.append(arg.tensor.idx) catch @panic("Failed to append to node stack.");
            }

            op.deinit();

            // To maintain graph invariants, we reduce deps
            // upon reversal. To keep an accurate picture of this
            // within the graph, now remove the actual dependency.
            self.node_block.ops.items[last] = null;
        }

        if (cleanup == .free) {
            UT.synchronize_stream(self.stream);

            for (free_stack.items) |node| {
                self.free_raw_tensor(self.node_block.data.items[node], .hid, node);
            }
        }
    }

    pub fn load(self: *Graph, dir: []const u8, prefix: []const u8) void {

        std.debug.assert(self.leaf_block.data.items.len != 0);

        var max_len: usize = 0;

        for (self.leaf_block.data.items) |u| {
            max_len = @max(max_len, u.bytes().len);
        }

        const buf = std.heap.c_allocator.alloc(u8, max_len) catch @panic("Failed to allocate cpu buffer");
        defer std.heap.c_allocator.free(buf);

        std.debug.assert(max_len != 0);

        // this is more stable than using the direct index
        // because inputs can come before or after, but
        // weights usually have fixed positions
        var wgt_idx: usize = 0;

        for (0..self.leaf_block.data.items.len) |i| {
            if (self.leaf_block.classes.items[i] == .wgt) {                

                const bytes = self.leaf_block.data.items[i].bytes();
                
                // we have uninitialized weights
                std.debug.assert(bytes.len != 0);
                
                loadTensorToGraph(dir, prefix, wgt_idx, bytes, buf[0..bytes.len], self.stream)
                    catch @panic("Failed to load tensor data.");

                wgt_idx += 1;
            }
        }
    }

    pub fn save(self: *Graph, dir: []const u8, prefix: []const u8) void {

        std.debug.assert(self.leaf_block.data.items.len != 0);

        var max_len: usize = 0;

        for (self.leaf_block.data.items) |u| {
            max_len = @max(max_len, u.bytes().len);
        }

        std.debug.assert(max_len != 0);

        // this is more stable than using the direct index
        // because inputs can come before or after, but
        // weights usually have fixed positions
        var wgt_idx: usize = 0;

        const buf = std.heap.c_allocator.alloc(u8, max_len) catch @panic("Failed to allocate cpu buffer");
        defer std.heap.c_allocator.free(buf);

        for (0..self.leaf_block.data.items.len) |i| {
            if (self.leaf_block.classes.items[i] == .wgt) {                

                const bytes = self.leaf_block.data.items[i].bytes();
                
                // we have uninitialized weights
                std.debug.assert(bytes.len != 0);
                
                saveTensorFromGraph(dir, prefix, wgt_idx, bytes, buf[0..bytes.len], self.stream)
                    catch @panic("Failed to save tensor data.");

                wgt_idx += 1;
            }
        }
    }
};

////////////////////////////////
// non-interface graph functions
////////////////////////////////

pub fn enable_gradient(t: Tensor) void {
    const self = t.ptr;
    const grad_array = if (t.class == .hid) 
        &self.node_block.grad else 
        &self.leaf_block.grad;
    const grad = &grad_array.items[t.idx];
    if (grad.* == null) {
        const size = t.len();
        grad.* = switch (t.dtype()) {
            .r16 => SliceUnion.init(self.tensor_allocator.alloc(SC.r16, size, self.stream)),
            .r32 => SliceUnion.init(self.tensor_allocator.alloc(SC.r32, size, self.stream)),
            .r64 => SliceUnion.init(self.tensor_allocator.alloc(SC.r64, size, self.stream)),
        };
    } 
}

pub fn adjust_deps(x: Tensor, direction: i32) i32 {
    std.debug.assert(x.class == .hid);
    const self = x.ptr;
    const items = self.node_block.deps.items;
    std.debug.assert(@abs(direction) <= 1);
    items[x.idx] += direction;
    return items[x.idx];
}

pub fn attach_op(
    comptime decls: type,
    t: Tensor,
    args: []const OpDatum,
) void {
    std.debug.assert(t.class == .hid);

    t.ptr.node_block.ops.items[t.idx] = 
        OpInterface.init(decls, args, t.ptr.node_arena.allocator());

    for (args, 0..) |*arg, i| {

        if (arg.* != .tensor)
            continue;

        if (arg.tensor.class != .hid)
            continue;

        // don't adjust the out argument
        if ((i + 1) == args.len)
            break;
            
        _ = adjust_deps(arg.tensor, 1);
    }
}

// this function can return scalar/tensor values
// use this instead of the tensor.derive function
// when building op.derive functions
pub fn derive(x: Tensor, wrt: Tensor) ?OpDatum {

    if (x.class != .hid)
        return if (x.same(wrt)) OpDatum{ .scalar = 1.0 } else null;

    if (x.ptr.node_block.ops.items[x.idx]) |*op| {
        return op.derive(wrt);
    }
    return null;
}

/////////////////////////////////////////////
/////////////////////////////////////////////

pub const OpInterface = struct {

    /// Pointer to the operation's virtual table
    vrt_ptr: *const OpVTable,
    
    /// Small buffer with pointer fallback
    args: OpArgs,
    
    pub fn init(
        comptime decls: type,
        args: []const OpDatum,
        allocator: std.mem.Allocator,
    ) OpInterface {
        return .{
            .args = OpArgs.init(args, allocator),
            .vrt_ptr = &.{
                .reverse = decls.reverse,   
                .derive = decls.derive,   
            },
        };
    }

    pub fn reverse(self: *const OpInterface) void {
        self.vrt_ptr.reverse(self.args.slice());        
    }

    pub fn derive(
        self: *const OpInterface,
        wrt: Tensor
    ) ?OpDatum {
        return self.vrt_ptr.derive(self.args.slice(), wrt);
    }

    pub fn deinit(self: *OpInterface) void {
        self.args.deinit();
        self.* = undefined;
    }
        
    // probably unnecessary...
    pub fn iterator(self: *const OpInterface) ArgIterator {
        return ArgIterator.init(self.args.slice());
    }
};

pub const OpDatum = union(enum) {
    tensor: Tensor,
    scalar: f64,
    expr: []const u8,
};

const OpVTable = struct {
    reverse: *const fn([]const OpDatum) void,
    derive: *const fn([]const OpDatum, Tensor) ?OpDatum,
};
    
pub const ArgIterator = struct {

    items: []const OpDatum,
    index: usize,

    pub fn init(items: []const OpDatum) ArgIterator {
        return .{
            .items = items,
            .index = 0,
        };
    }

    pub fn next(self: *ArgIterator) ?OpDatum {
        if (self.index < self.items.len) {
            defer self.index += 1;
            return self.items[self.index];
        }
        return null;
    }
};

pub const OpArgs = struct {

    const inplace_size: usize = 6;
    const InplaceType = std.BoundedArray(OpDatum, inplace_size);

    items: union(enum) {
        inplace: InplaceType,
        overage: []OpDatum,
    },

    pub fn init(args: []const OpDatum, allocator: std.mem.Allocator) OpArgs {
        if (args.len <= inplace_size) {
            return .{ 
                .items = .{ .inplace = InplaceType.fromSlice(args) catch unreachable } 
            };
        } else {
            return .{ 
                .items = .{ .overage = allocator.dupe(OpDatum, args) catch @panic("failed to allocate argument buffer") }
            };
        }
    }

    pub fn deinit(self: *OpArgs) void {
        if (self.items == .overage) {
            std.heap.c_allocator.free(self.items.overage);
        }
    }

    pub fn slice(self: *const OpArgs) []const OpDatum {
        return switch (self.items) {
            .inplace => |*buf| buf.slice(),
            .overage => |ovg| ovg,
        };
    }
};

