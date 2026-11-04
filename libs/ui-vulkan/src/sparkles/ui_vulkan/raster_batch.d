/**
Bounded, synchronous batches of independent coverage tiles. Event Horizon
workers own their decoding and raster scratch; the caller owns font bytes
and instances until `run` returns. Atlas placement and GPU uploads stay on
the rendering thread. Oversized jobs fall back to the ordinary raster path.
*/
module sparkles.ui_vulkan.raster_batch;

import core.time : MonoTime;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.sync : Semaphore;
import sparkles.event_horizon.raw_pool : RawCpuPool, RawJob, RawPoolResult;
import sparkles.shaders : vec4;
import sparkles.ui_vulkan.coverage_geometry : CoverageLayout, CoverageMode, CoverageWork, packCoverageEdges;
import sparkles.font : FontErrorKind, FontLimit, Instance, LightHints, OutlinePoint,
    OutlineSegment, OverlapMode, Ppem, prepareRaster, RasterEdge, RasterGlyph, RasterRegion, RasterWorkspace;

/// Immutable inputs borrowed for one completed batch.
struct RasterRequest
{
    Instance instance;
    uint glyph;
    Ppem ppem;
    LightHints hints;
    bool hinted;
}

/// A worker-owned tile. An unready tile asks the caller to use its usual path.
struct RasterTile
{
    bool ready;
    RasterGlyph metrics;
    UniqueBuffer!ubyte pixels;
    UniqueBuffer!RasterEdge edges;
    UniqueBuffer!vec4 geometry;
    CoverageLayout layout;
    CoverageWork work;
    bool unionCoverage;
    bool geometryReady;
}

private struct Scratch
{
    UniqueBuffer!OutlineSegment segments;
    UniqueBuffer!OutlinePoint points;
    UniqueBuffer!bool onCurve;
    UniqueBuffer!ushort ends;
    UniqueBuffer!uint numbers;
    UniqueBuffer!int dx, dy;
    UniqueBuffer!(int[2]) referenced;
    UniqueBuffer!float accumulation;
    UniqueBuffer!ubyte supersample;

    bool grow() @safe pure nothrow @nogc
    {
        const n = points.length ? points.length * 2 : 1024;
        if (n > 32_768) return false;
        segments.length = n * 2;
        points.length = n;
        onCurve.length = n;
        numbers.length = n;
        dx.length = n;
        dy.length = n;
        referenced.length = n;
        ends.length = n / 4;
        return true;
    }

    RasterWorkspace workspace() return @safe pure nothrow @nogc
        => RasterWorkspace(segments[], points[], onCurve[], ends[], accumulation[], supersample[],
            numbers[], dx[], dy[], referenced[]);
}

private void rasterTile(in RasterRequest request, ref RasterTile tile, ref Scratch scratch,
    CoverageMode mode = CoverageMode.cpu, bool profile = false)
    @safe nothrow @nogc
{
    tile.ready = false;
    tile.geometryReady = false;
    tile.work = CoverageWork.init;
    tile.work.glyphs = 1;
    if (!scratch.points.length) cast(void) scratch.grow();
    LightHints hints = request.hints;
    foreach (_; 0 .. 6)
    {
        auto start = profile ? MonoTime.currTime : MonoTime.init;
        const plan = prepareRaster(request.instance, request.glyph, request.ppem, scratch.workspace,
            OverlapMode.perGlyphFlag, request.hinted ? &hints : null);
        if (profile) tile.work.prepareNs += (MonoTime.currTime - start).total!"nsecs";
        if (plan.hasError)
        {
            if (plan.error.kind == FontErrorKind.limitExceeded && plan.error.limit == FontLimit.callerStorage
                && scratch.grow()) continue;
            return;
        }
        const m = plan.value.metrics;
        if (mode != CoverageMode.cpu && m.width >= 0 && m.height >= 0
            && m.width <= 128 && m.height <= 128 && cast(ulong)m.width * m.height <= 8192)
        {
            tile.edges.length = 512;
            if (profile) start = MonoTime.currTime;
            const result = plan.value.edges(tile.edges[]);
            if (profile) tile.work.flattenNs += (MonoTime.currTime - start).total!"nsecs";
            if (result.hasValue)
            {
                tile.edges.length = result.value;
                if (profile) start = MonoTime.currTime;
                tile.layout = packCoverageEdges(tile.edges[], cast(uint)m.height,
                    mode == CoverageMode.bands, tile.geometry);
                if (profile) tile.work.packNs += (MonoTime.currTime - start).total!"nsecs";
                tile.work.edges = tile.edges.length;
                tile.work.texels = tile.geometry.length;
                tile.work.bandStrideSum = tile.layout.stride;
                tile.metrics = m;
                // Collapsed horizontal contours cover no pixels. Remember
                // them as blank instead of binding an unstaged image.
                if (!result.value) tile.metrics.empty = true;
                tile.work.geometryGlyphs = tile.metrics.empty ? 0 : 1;
                tile.unionCoverage = plan.value.unionCoverage;
                tile.geometryReady = true;
                tile.ready = true;
                return;
            }
            // A geometry limit is not a raster limit. Reuse the prepared
            // outline for a CPU tile on this worker, without another decode.
        }
        // Hard scratch/tile budgets. Larger supported glyphs use the regular
        // caller path, which can provision their full workspace.
        if (m.width < 0 || m.height < 0 || m.width > 1023 || m.height > 1023
            || cast(ulong)m.width * m.height > 65_536 || m.accumulationNeeded > 1_048_576)
            return;
        if (scratch.accumulation.length < m.accumulationNeeded)
            scratch.accumulation.length = m.accumulationNeeded;
        if (scratch.supersample.length < m.supersampleNeeded)
            scratch.supersample.length = m.supersampleNeeded;
        tile.pixels.length = cast(size_t)m.width * m.height;
        if (profile) start = MonoTime.currTime;
        const drawn = plan.value.rasterize(RasterRegion(tile.pixels[], m.width, m.width, m.height),
            scratch.workspace);
        if (profile) tile.work.rasterNs += (MonoTime.currTime - start).total!"nsecs";
        if (drawn.hasError) return;
        tile.metrics = drawn.value;
        tile.work.fallbackGlyphs = mode == CoverageMode.cpu ? 0 : 1;
        tile.ready = true;
        return;
    }
}

/// Address-stable owner, with no queued work surviving a completed `run`.
struct RasterBatch(size_t MaxJobs = 128)
{
    @disable this(this);
    private RawCpuPool!(4, 4) pool;
    private bool started;
    private RasterTile[MaxJobs] tiles_;
    private const(RasterRequest)[] requests_;
    private CoverageMode mode_;
    private bool profile_;
    private struct Worker
    {
        RasterBatch* owner;
        size_t first, stride;
        Scratch scratch;
        Semaphore done;
    }
    private Worker[4] workers_;

    private static void work(void* context) @safe nothrow @nogc
    {
        auto worker = (() @trusted => cast(Worker*)context)();
        auto batch = worker.owner;
        for (size_t i = worker.first; i < batch.requests_.length; i += worker.stride)
            rasterTile(batch.requests_[i], batch.tiles_[i], worker.scratch, batch.mode_, batch.profile_);
        worker.done.release();
    }

    /// Runs 1–4 workers, falling back to the calling thread if the pool fails.
    /// Requests beyond the hard job limit are not accepted.
    void run(in RasterRequest[] requests, uint workers = 2, CoverageMode mode = CoverageMode.cpu,
        bool profile = false) @system nothrow
    {
        assert(requests.length <= MaxJobs);
        requests_ = requests;
        mode_ = mode;
        profile_ = profile;
        scope (exit) requests_ = null;
        if (!requests.length) return;
        workers = workers < 1 ? 1 : workers > 4 ? 4 : workers;
        // A short batch must not tear down the configured persistent pool.
        // Run one tile inline; otherwise wake only as many workers as needed.
        if (requests.length == 1)
        {
            rasterTile(requests[0], tiles_[0], workers_[0].scratch, mode, profile);
            return;
        }
        if (started && pool.workerCount != workers) stop();
        if (workers > 1 && !started)
            started = typeof(pool).start(pool, workers) == RawPoolResult.accepted;
        if (workers == 1 || !started)
        {
            foreach (i, ref const request; requests)
                rasterTile(request, tiles_[i], workers_[0].scratch, mode, profile);
            return;
        }
        const active = workers > requests.length ? cast(uint)requests.length : workers;
        foreach (i; 0 .. active)
        {
            auto worker = &workers_[i];
            worker.owner = &this;
            worker.first = i;
            worker.stride = active;
            if (pool.submit(RawJob(&work, null, worker)) != RawPoolResult.accepted)
                work(worker);
        }
        foreach (i; 0 .. active) workers_[i].done.acquire();
    }

    /// Completed immutable tile, borrowed until the next run or destruction.
    ref const(RasterTile) tile(size_t i) const return @safe pure nothrow @nogc
        => tiles_[i];

    /// Joins workers; safe after any completed batch and before renderer teardown.
    void stop() @safe nothrow
    {
        if (started) cast(void) pool.shutdown(true);
        started = false;
    }

    ~this() @safe nothrow { stop(); }
}
