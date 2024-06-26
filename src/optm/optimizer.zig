const TC = @import("tensor_components.zig");
const SliceUnion = TC.SliceUnion;
const SC = @import("scalar.zig");
const Stream = @import("device_utils.zig").Stream;
const overloads = @import("kernel_overloads.zig");
const std = @import("std");
const IndexType = @import("tensor_components.zig").IndexType;
const GraphID = usize; // convert graph ptr to number
const Child = @import("utility.zig").Child;
const Graph = @import("graph.zig").Graph;
const DU = @import("device_utils.zig");
const Algo = @import("algorithm.zig");

// key for stateful optimizer maps
const KeyPair = struct {
    gid: usize, // graph id
    wid: usize, // weight id
};

const ClipRange = struct {
    lower: f32,
    upper: f32,

    // clip at +/-inf bypasses clipping
    pub fn init() ClipRange {
        return .{
            .lower = -std.math.inf(f32),
            .upper = std.math.inf(f32),
        };
    }
};

// Some optimizers need to store extra data about the
// weight gradients (like momentum). We pass in both
// the GraphID and the current weight index to make
// hashing possible in the case of multiple graphs
// per optimizer.


const WeightIterator = struct {
    idx: usize = 0,
    ptr: *Graph,

    pub fn init(graph: *Graph) WeightIterator {
        return .{ .ptr = graph, .idx = 0 };
    }

    pub fn next(self: *WeightIterator) ?struct { 
        idx: IndexType,
        wgt: SliceUnion,
        grd: SliceUnion,
        stream: Stream,
    }{
        // TODO: Consider if leaves.dependencies should be considered? Would allow partial update.
        
        while (self.idx < self.ptr.leaves.values.items.len) : (self.idx += 1){

            const grads = self.ptr.leaves.grads.items[self.idx];

            if (grads) |grd| {
                defer self.idx += 1;
                
                const wgt = self.ptr.leaves.values.items[self.idx];
                const stream = self.ptr.leaves.streams.items[self.idx];

                return .{
                    .idx = self.idx,
                    .wgt = wgt,
                    .grd = grd,
                    .stream = stream,
                };
            }
        }
        return null;
    }
    
};


//pub const Optimizer = struct {
//    opt_ptr: *anyopaque,
//    upd_ptr: *const fn (
//        *anyopaque,
//        GraphID, // graph ptr value
//        IndexType, // index of weight
//        SliceUnion, // raw wgt values
//        SliceUnion, // raw grd values
//        Stream, // stream of wgt
//    ) void,
//
//    pub inline fn update(self: Optimizer, gid: GraphID, wid: IndexType, wgt: SliceUnion, grd: SliceUnion, stream: Stream) void {
//        self.upd_ptr(self.opt_ptr, gid, wid, wgt, grd, stream);
//    }
//};

// helper to deduce dispatchable types... not strictly needed
inline fn updateDispatch(
    opt: anytype,
    gid: GraphID,
    wid: IndexType,
    wgt: SliceUnion,
    grd: SliceUnion,
    stream: Stream,
) void {
    switch (wgt) {
        .r16 => opt.optimize(gid, wid, wgt.r16, grd.r16, stream),
        .r32 => opt.optimize(gid, wid, wgt.r32, grd.r32, stream),
        .r64 => opt.optimize(gid, wid, wgt.r64, grd.r64, stream),
        //.c16 => opt.optimize(gid, wid, wgt.c16, grd.c16, stream),
        //.c32 => opt.optimize(gid, wid, wgt.c32, grd.c32, stream),
        //.c64 => opt.optimize(gid, wid, wgt.r64, grd.r64, stream),
        else => @panic("Optimizer: TODO - q8"),
    }
}

//pub const NullOptimizer = struct {
//
//    // "It's a show about nothing! It does nothing... but it does it in style!"
//    //     ~ Andrei Alexandrescu
//
//    fn update(_: *anyopaque, _: GraphID, _: IndexType, _: SliceUnion, _: SliceUnion, _: Stream) void {
//        return {};
//    }
//};

pub const SGD = struct {
    rate: f32,
    clip: ClipRange,

    pub fn init(config: struct {
        rate: f32,
        clip: ?ClipRange = null,
    }) SGD {
        return .{
            .rate = config.rate,
            .clip = config.clip orelse ClipRange.init(),
        };
    }

    pub fn update(self: *SGD, graph: *Graph) void {

        // only synchronize active streams once
        var unique = std.StaticBitSet(DU.MAX_STREAMS).initEmpty();

        var itr = WeightIterator.init(graph);

        while (itr.next()) |pkg| {
            updateDispatch(self, graph.id(), pkg.idx, pkg.wgt, pkg.grd, pkg.stream);
            unique.setValue(pkg.stream.ID, true);
        }

        // synchronize all unique streams
        for (0..DU.MAX_STREAMS) |i| {
            if (unique.isSet(i)) DU.synchronizeStream(&DU.stream_array[i].?);
        }
    }

    ///////////////////////////////////////////////////////////////////

    inline fn optimize(
        self: *SGD,
        _: GraphID,
        _: IndexType,
        wgt: anytype,
        grd: anytype,
        stream: Stream,
    ) void {
        std.debug.assert(wgt.len == grd.len);
        const T = Child(@TypeOf(grd));
        overloads.kernel_gradient_descent.call(.{
            stream.context,
            wgt.ptr,
            grd.ptr,
            SC.asScalar(T, self.rate),
            SC.asScalar(T, self.clip.lower),
            SC.asScalar(T, self.clip.upper),
            wgt.len,
        });
    }
};

pub const Momentum = struct {

    const StateMap = std.AutoHashMap(KeyPair, SliceUnion);
    
    rate: f32,
    alpha: f32,
    clip: ClipRange,
    map: StateMap,

    // TODO: consider letting the user pass an allocator
    pub fn init(config: struct {
        rate: f32,
        alpha: ?f32,
        clip: ?ClipRange = null,
        allocator: ?std.mem.Allocator = null,
    }) Momentum {
        const alpha = if (config.alpha) |a| a else @as(f32, 0.90);

        std.debug.assert((0.0 < alpha) and (alpha < 1.0));
                
        return .{
            .rate = config.rate,
            .alpha = alpha,
            .clip = config.clip orelse ClipRange.init(),
            .map = StateMap.init(if (config.allocator) |a| a else std.heap.c_allocator),
        };
    }

    pub fn deinit(self: *Momentum, stream: Stream) void {
        var itr = self.map.keyIterator();
        while (itr.next()) |key| {
            const u = self.map.get(key.*) orelse unreachable;
            DU.free(u.bytes(), stream);
        }
        self.map.deinit();
    }

    pub fn update(self: *Momentum, graph: *Graph) void {

        // only synchronize active streams once
        var unique = std.StaticBitSet(DU.MAX_STREAMS).initEmpty();

        var itr = WeightIterator.init(graph);

        while (itr.next()) |pkg| {
            updateDispatch(self, graph.id(), pkg.idx, pkg.wgt, pkg.grd, pkg.stream);
            unique.setValue(pkg.stream.ID, true);
        }

        // synchronize all unique streams
        for (0..DU.MAX_STREAMS) |i| {
            if (unique.isSet(i)) DU.synchronizeStream(&DU.stream_array[i].?);
        }
    }

    ///////////////////////////////////////////////////////////////////

    inline fn optimize(
        self: *Momentum,
        gid: GraphID,
        wid: IndexType,
        wgt: anytype,
        grd: anytype,
        stream: Stream,
    ) void {
        const T = Child(@TypeOf(grd));

        const res = self.map.getOrPut(KeyPair{ .gid = gid, .wid = wid })
            catch @panic("Failed to put value into map");

        if (!res.found_existing) {
            const mtm = DU.alloc(T, grd.len, stream);
            Algo.fillSlice(T, mtm, 0.0, stream);
            res.value_ptr.* = SliceUnion.init(mtm);
        }

        const mtm = TC.getSlice(T, res.value_ptr.*);
        
        std.debug.assert(wgt.len == grd.len);
        std.debug.assert(mtm.len == grd.len);

        overloads.kernel_momentum.call(.{
            stream.context,
            wgt.ptr,
            grd.ptr,
            mtm.ptr,
            SC.asScalar(T, self.rate),
            SC.asScalar(T, self.alpha),
            SC.asScalar(T, self.clip.lower),
            SC.asScalar(T, self.clip.upper),
            wgt.len,
        });
    }
};
