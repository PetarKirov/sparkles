/**
Per-terminal Kitty textures and placement rendering. The C ABI has no image
revision, so an owned pixel snapshot is compared at most once per VT mutation
epoch. Borrowed Ghostty handles never survive a method call. Texture/snapshot
storage is bounded; placement sorting uses bounded batches without dropping
placements when a terminal exceeds the batch size.
*/
module sparkles.terminal_view.kitty_images;

import core.stdc.string : memcmp, memcpy;

import std.algorithm.sorting : sort;

import raylib : Color, DrawTexturePro, Image, LoadTextureFromImage, PixelFormat,
    Rectangle, SetTextureFilter, Texture2D, TextureFilter, UnloadTexture,
    UpdateTextureRec, Vector2;
import raylib.rlgl : rlDrawRenderBatchActive;

import sparkles.base.buffer : Buffer, UniqueBuffer;
import sparkles.ghostty.c;

/**
Owns all image resources for one terminal. Call `prepare` before the three
`drawLayer` calls, advancing `mutationEpoch` whenever VT input is consumed.
Call `release` before the window/GL context is destroyed. No window is needed
when no textures have been loaded. All calls run on the render thread, with
no terminal mutations between prepare and the last layer.
*/
struct KittyImageRenderer
{
    private enum maxImages = 256;
    // A 64 MiB gray image (the terminal's storage limit) can need a 256 MiB
    // RGBA GPU allocation as well as its 64 MiB exact CPU snapshot.
    private enum maxBytes = 320UL * 1024 * 1024;
    private enum placementBatchSize = 4096;

    private CachedImage[maxImages] images;
    private UniqueBuffer!(Placement, 16) placements;
    private UniqueBuffer!(CapturedImage, 16) capturedImages;
    private UniqueBuffer!(Placement, 16) capturedPlacements;
    private bool captured;
    private ulong residentBytes;
    private ulong useClock;
    private ulong epoch;
    private bool prepared;
    private GhosttyTerminalScreen screen;
    private int cellWidth;
    private int cellHeight;
    private KittyMutationScanner mutations;

    /// Remains pending through frozen paints; only a live paint clears it.
    bool repaintPending;

    /// Observe existing feed-loop bytes without decoding or retaining payloads.
    void observeByte(char b) @safe pure nothrow @nogc
    {
        repaintPending |= mutations.scan(b);
    }

    package bool skipsPrintable() const @safe pure nothrow @nogc
        => mutations.skipsPrintable;

    @disable this(this);

    @system nothrow @nogc:

    void prepare(GhosttyTerminal terminal, ulong mutationEpoch,
        int width, int height)
    {
        if (captured)
        {
            foreach (ref image; images)
                image.checked = false;
            releaseCapture();
            prepared = false;
        }
        GhosttyTerminalScreen activeScreen;
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &activeScreen);
        const changedScreen = prepared && screen != activeScreen;
        if (changedScreen)
            releaseImages();
        screen = activeScreen;
        cellWidth = width;
        cellHeight = height;

        // Deletion is independent of placement visibility: an image removed
        // while off screen must not keep its texture until it is drawn again.
        if (!prepared || changedScreen || epoch != mutationEpoch)
        {
            auto graphics = graphicsFor(terminal);
            foreach (ref image; images)
                if (image.texture.id != 0 && (graphics is null ||
                    ghostty_kitty_graphics_image(graphics, image.id) is null))
                    retire(image);
        }
        epoch = mutationEpoch;
        prepared = true;
    }

    void drawLayer(GhosttyTerminal terminal,
        GhosttyKittyGraphicsPlacementIterator iterator,
        GhosttyKittyPlacementLayer layer)
    {
        auto graphics = graphicsFor(terminal);
        if (graphics is null || iterator is null)
            return;

        Placement after;
        bool hasAfter;
        for (;;)
        {
            placements.clear(releaseStorage: false);
            bool more;
            ghostty_kitty_graphics_placement_iterator_set(iterator,
                GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER, &layer);
            if (ghostty_kitty_graphics_get(graphics,
                GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator) != GHOSTTY_SUCCESS)
                return;

            while (ghostty_kitty_graphics_placement_next(iterator))
            {
                Placement placement;
                ghostty_kitty_graphics_placement_get(iterator,
                    GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &placement.imageId);
                ghostty_kitty_graphics_placement_get(iterator,
                    GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placement.placementId);
                ghostty_kitty_graphics_placement_get(iterator,
                    GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &placement.z);
                if (hasAfter && !placementBefore(after, placement))
                    continue;

                if (!readPlacementGeometry(terminal, graphics, iterator, placement,
                    cellWidth, cellHeight))
                    continue;
                placements ~= placement;

                // Keep the first sorted batch in bounded scratch space. Very
                // large placement sets continue from the last key in another
                // scan; none are silently discarded at the memory limit.
                if (placements.length == 2 * placementBatchSize)
                {
                    sort!placementBefore(placements[]);
                    placements.length = placementBatchSize;
                    more = true;
                }
            }
            if (placements.length > placementBatchSize)
            {
                sort!placementBefore(placements[]);
                placements.length = placementBatchSize;
                more = true;
            }
            sort!placementBefore(placements[]);
            foreach (ref const placement; placements[])
            {
                const texture = textureFor(graphics, placement.imageId);
                if (texture.id != 0)
                    DrawTexturePro(texture, placement.source, placement.destination,
                        Vector2(0, 0), 0, Color(255, 255, 255, 255));
            }
            if (!more || placements.empty)
                break;
            after = placements[$ - 1];
            hasAfter = true;
        }
    }

    /**
    Freeze the image state at a synchronized-output boundary. CPU-only: this
    also works for a headless terminal. Pixel storage is owned once per image,
    bounded by the terminal's configured image storage limit; placement metadata
    is retained only for the duration of the hold.
    */
    void capture(GhosttyTerminal terminal,
        GhosttyKittyGraphicsPlacementIterator iterator, int width, int height)
    {
        releaseCapture();
        captured = true;
        foreach (ref image; images)
            image.checked = false;
        auto graphics = graphicsFor(terminal);
        if (graphics is null || iterator is null)
            return;
        GhosttyKittyPlacementLayer layer = GHOSTTY_KITTY_PLACEMENT_LAYER_ALL;
        ghostty_kitty_graphics_placement_iterator_set(iterator,
            GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER, &layer);
        if (ghostty_kitty_graphics_get(graphics,
            GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator) != GHOSTTY_SUCCESS)
            return;
        while (ghostty_kitty_graphics_placement_next(iterator))
        {
            Placement placement;
            ghostty_kitty_graphics_placement_get(iterator,
                GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &placement.imageId);
            ghostty_kitty_graphics_placement_get(iterator,
                GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placement.placementId);
            ghostty_kitty_graphics_placement_get(iterator,
                GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &placement.z);
            if (!readPlacementGeometry(terminal, graphics, iterator, placement, width, height))
                continue;
            size_t index;
            while (index < capturedImages.length && capturedImages[index].id != placement.imageId)
                ++index;
            if (index == capturedImages.length)
            {
                PixelView view;
                if (!readPixels(ghostty_kitty_graphics_image(graphics, placement.imageId), view))
                    continue;
                CapturedImage frozen;
                frozen.id = placement.imageId;
                frozen.width = view.width;
                frozen.height = view.height;
                frozen.format = view.format;
                frozen.rowBytes = view.rowBytes;
                auto cached = findImage(placement.imageId);
                if (cached !is null && samePixels(*cached, view))
                    frozen.pixels = cached.pixels;
                else
                    frozen.pixels ~= view.pixels;
                capturedImages ~= frozen;
            }
            placement.captureIndex = index;
            capturedPlacements ~= placement;
        }
        sort!placementBefore(capturedPlacements[]);
    }

    /// Paint only owned state, never the terminal that is changing under a hold.
    void drawCapturedLayer(GhosttyKittyPlacementLayer layer)
    {
        foreach (ref const placement; capturedPlacements[])
        {
            if (placementLayer(placement.z) != layer)
                continue;
            ref image = capturedImages[placement.captureIndex];
            const ref pixels = image.pixels;
            const view = PixelView(image.width, image.height, image.format, image.rowBytes,
                pixels[]);
            const texture = textureForView(image.id, view, findImage(image.id), &image.pixels);
            if (texture.id != 0)
                DrawTexturePro(texture, placement.source, placement.destination,
                    Vector2(0, 0), 0, Color(255, 255, 255, 255));
        }
    }

    /// Flush queued draws before deleting resources; safe to call repeatedly.
    void release()
    {
        releaseImages();
        placements.clear();
        releaseCapture();
        prepared = false;
        useClock = 0;
        mutations = KittyMutationScanner.init;
        repaintPending = false;
    }

private:
    void releaseCapture()
    {
        foreach (ref image; capturedImages[])
            image.pixels.clear();
        capturedImages.clear();
        capturedPlacements.clear();
        captured = false;
    }

    void releaseImages()
    {
        foreach (ref image; images)
            retire(image);
    }

    void retire(ref CachedImage image)
    {
        if (image.texture.id != 0)
        {
            // A different pane or an earlier placement in this very layer can
            // still reference the texture in raylib's CPU-side render batch.
            rlDrawRenderBatchActive();
            UnloadTexture(image.texture);
        }
        residentBytes -= image.bytes;
        image.texture = Texture2D.init;
        image.pixels.clear();
        image.bytes = 0;
        image.checked = false;
    }

    CachedImage* findImage(uint id)
    {
        foreach (ref image; images)
            if (image.texture.id != 0 && image.id == id)
                return &image;
        return null;
    }

    Texture2D textureFor(GhosttyKittyGraphics graphics, uint id)
    {
        auto cached = findImage(id);
        if (cached !is null && cached.checked && cached.epoch == epoch)
        {
            cached.lastUse = ++useClock;
            return cached.texture;
        }
        PixelView view;
        if (!readPixels(ghostty_kitty_graphics_image(graphics, id), view))
        {
            if (cached !is null)
                retire(*cached);
            return Texture2D.init;
        }
        return textureForView(id, view, cached);
    }

    Texture2D textureForView(uint id, in PixelView view, CachedImage* cached,
        Buffer!ubyte* ownedPixels = null)
    {
        if (cached !is null && cached.checked && cached.epoch == epoch)
        {
            cached.lastUse = ++useClock;
            return cached.texture;
        }
        if (cached !is null && cached.width == view.width &&
            cached.height == view.height && cached.format == view.format)
        {
            const ref saved = cached.pixels;
            const rows = changedRows(saved[], view);
            if (rows.count != 0)
            {
                rlDrawRenderBatchActive();
                const start = rows.first * view.rowBytes;
                const length = rows.count * view.rowBytes;
                UpdateTextureRec(cached.texture,
                    Rectangle(0, rows.first, view.width, rows.count), view.pixels.ptr + start);
                if (ownedPixels !is null)
                    cached.pixels = *ownedPixels;
                else
                    memcpy(cached.pixels[].ptr + start, view.pixels.ptr + start, length);
            }
        }
        else
        {
            if (cached !is null)
                retire(*cached);
            // Account for the snapshot's power-of-two allocation and an RGBA
            // GPU backing even for RGB/gray, which drivers may expand.
            const bytes = allocationBytes(view);
            if (bytes > maxBytes)
                return Texture2D.init;
            while (residentBytes + bytes > maxBytes)
                retire(*oldestImage());
            if (cached is null)
            {
                foreach (ref image; images)
                    if (image.texture.id == 0)
                    {
                        cached = &image;
                        break;
                    }
                if (cached is null)
                {
                    cached = oldestImage();
                    retire(*cached);
                }
            }

            Image source = {
                data: cast(void*) view.pixels.ptr,
                width: cast(int) view.width,
                height: cast(int) view.height,
                mipmaps: 1,
                format: view.format,
            };
            cached.texture = LoadTextureFromImage(source);
            if (cached.texture.id == 0)
                return Texture2D.init;
            SetTextureFilter(cached.texture, TextureFilter.TEXTURE_FILTER_BILINEAR);
            if (ownedPixels !is null)
                cached.pixels = *ownedPixels;
            else
                cached.pixels ~= view.pixels;
            cached.id = id;
            cached.width = view.width;
            cached.height = view.height;
            cached.format = view.format;
            cached.bytes = bytes;
            residentBytes += bytes;
        }
        cached.checked = true;
        cached.epoch = epoch;
        cached.lastUse = ++useClock;
        return cached.texture;
    }

    CachedImage* oldestImage()
    {
        CachedImage* oldest;
        foreach (ref image; images)
            if (image.texture.id != 0 &&
                (oldest is null || image.lastUse < oldest.lastUse))
                oldest = &image;
        assert(oldest !is null);
        return oldest;
    }
}

// Ghostty's C render dirty flag only covers the cell grid, not its independent
// kitty_images.dirty bit. Observe completed mutating APCs, never ordinary VT
// traffic or a=q capability probes. Invalid mutations may conservatively paint.
private struct KittyMutationScanner
{
    private enum State { ground, escape, apc, header, payload, end, ignored, ignoredEnd }
    private State state;
    private char action;
    private char key;
    private uint fieldPosition;
    private bool osc;

    bool skipsPrintable() const @safe pure nothrow @nogc
        => state == State.ground || state == State.payload || state == State.ignored;

    bool scan(char b) @safe pure nothrow @nogc
    {
        if (b == '\x18' || b == '\x1a')
        {
            state = State.ground;
            return false;
        }
        final switch (state)
        {
            case State.ground:
                if (b == '\x1b') state = State.escape;
                break;
            case State.escape:
                if (b == '_')
                    state = State.apc;
                else if (b == ']' || b == 'P' || b == '^')
                {
                    osc = b == ']';
                    state = State.ignored;
                }
                else if (b != '\x1b')
                    state = State.ground;
                break;
            case State.apc:
                osc = false;
                state = b == 'G' ? State.header : State.ignored;
                action = 't';
                fieldPosition = 0;
                break;
            case State.header:
                if (b == '\x1b')
                    state = State.end;
                else if (b == ';')
                    state = State.payload;
                else if (b == ',')
                    fieldPosition = 0;
                else if (fieldPosition == 0)
                {
                    key = b;
                    fieldPosition = 1;
                }
                else if (fieldPosition == 1)
                    fieldPosition = b == '=' ? 2 : 3;
                else if (fieldPosition == 2)
                {
                    if (key == 'a') action = b;
                    fieldPosition = 3;
                }
                break;
            case State.payload:
                if (b == '\x1b') state = State.end;
                break;
            case State.end:
                state = b == '\x1b' ? State.escape : State.ground;
                return b == '\\' && (action == 't' || action == 'T' ||
                    action == 'p' || action == 'd');
            case State.ignored:
                if (b == '\x1b') state = State.ignoredEnd;
                else if (osc && b == '\x07') state = State.ground;
                break;
            case State.ignoredEnd:
                state = b == '\\' ? State.ground : State.ignored;
                break;
        }
        return false;
    }
}

private struct CachedImage
{
    uint id;
    uint width;
    uint height;
    int format;
    Texture2D texture;
    Buffer!ubyte pixels;
    ulong bytes;
    ulong epoch;
    ulong lastUse;
    bool checked;
}

private struct CapturedImage
{
    uint id;
    uint width;
    uint height;
    int format;
    size_t rowBytes;
    Buffer!ubyte pixels;
}

private bool samePixels(in CachedImage image, in PixelView view) @system nothrow @nogc
    => image.width == view.width && image.height == view.height &&
        image.format == view.format && image.pixels.length == view.pixels.length &&
        memcmp(image.pixels[].ptr, view.pixels.ptr, view.pixels.length) == 0;

private struct Placement
{
    uint imageId;
    uint placementId;
    int z;
    Rectangle source;
    Rectangle destination;
    size_t captureIndex;
}

private bool placementBefore(in Placement a, in Placement b) @safe pure nothrow @nogc
    => a.z != b.z ? a.z < b.z :
        a.imageId != b.imageId ? a.imageId < b.imageId : a.placementId < b.placementId;

private GhosttyKittyPlacementLayer placementLayer(int z) @safe pure nothrow @nogc
    => z < int.min / 2 ? GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG :
        z < 0 ? GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT : GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT;

private bool readPlacementGeometry(GhosttyTerminal terminal, GhosttyKittyGraphics graphics,
    GhosttyKittyGraphicsPlacementIterator iterator, ref Placement placement,
    int cellWidth, int cellHeight) @system nothrow @nogc
{
    auto handle = ghostty_kitty_graphics_image(graphics, placement.imageId);
    if (handle is null)
        return false;
    GhosttyKittyGraphicsPlacementRenderInfo info;
    info.size = info.sizeof;
    if (ghostty_kitty_graphics_placement_render_info(iterator, handle, terminal,
        &info) != GHOSTTY_SUCCESS || !info.viewport_visible ||
        info.pixel_width == 0 || info.pixel_height == 0 ||
        info.source_width == 0 || info.source_height == 0)
        return false;
    uint xOffset, yOffset;
    ghostty_kitty_graphics_placement_get(iterator,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &xOffset);
    ghostty_kitty_graphics_placement_get(iterator,
        GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &yOffset);
    placement.source = Rectangle(info.source_x, info.source_y,
        info.source_width, info.source_height);
    placement.destination = destinationRect(info, xOffset, yOffset, cellWidth, cellHeight);
    return true;
}

private Rectangle destinationRect(in GhosttyKittyGraphicsPlacementRenderInfo info,
    uint xOffset, uint yOffset, int cellWidth, int cellHeight) @safe pure nothrow @nogc
    => Rectangle(cast(float) info.viewport_col * cellWidth + xOffset,
        cast(float) info.viewport_row * cellHeight + yOffset,
        info.pixel_width, info.pixel_height);

private struct PixelView
{
    uint width;
    uint height;
    int format;
    size_t rowBytes;
    const(ubyte)[] pixels;
}

private bool pixelLayout(GhosttyKittyImageFormat format, out int raylibFormat,
    out uint channels) @safe pure nothrow @nogc
{
    switch (format)
    {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            raylibFormat = PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8;
            channels = 3;
            return true;
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            raylibFormat = PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;
            channels = 4;
            return true;
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA:
            raylibFormat = PixelFormat.PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA;
            channels = 2;
            return true;
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:
            raylibFormat = PixelFormat.PIXELFORMAT_UNCOMPRESSED_GRAYSCALE;
            channels = 1;
            return true;
        default:
            return false;
    }
}

private bool readPixels(GhosttyKittyGraphicsImage image, out PixelView view)
    @system nothrow @nogc
{
    if (image is null)
        return false;
    GhosttyKittyImageFormat format;
    const(ubyte)* pixels;
    size_t length;
    GhosttyKittyGraphicsImageData[5] keys = [GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
        GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
        GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN];
    void*[5] values = [cast(void*) &view.width, cast(void*) &view.height,
        cast(void*) &format, cast(void*) &pixels, cast(void*) &length];
    if (ghostty_kitty_graphics_image_get_multi(image, keys.length, keys.ptr,
        values.ptr, null) != GHOSTTY_SUCCESS)
        return false;
    uint channels;
    if (!pixelLayout(format, view.format, channels) || pixels is null ||
        view.width == 0 || view.height == 0 ||
        view.width > int.max || view.height > int.max)
        return false;
    const bytes = cast(ulong) view.width * view.height * channels;
    if (bytes > length || bytes > size_t.max)
        return false;
    view.rowBytes = cast(size_t) view.width * channels;
    view.pixels = pixels[0 .. cast(size_t) bytes];
    return true;
}

private GhosttyKittyGraphics graphicsFor(GhosttyTerminal terminal)
    @system nothrow @nogc
{
    GhosttyKittyGraphics graphics;
    return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
        &graphics) == GHOSTTY_SUCCESS ? graphics : null;
}

private ulong allocationBytes(in PixelView view) @safe pure nothrow @nogc
{
    ulong snapshot = 1;
    while (snapshot < view.pixels.length)
        snapshot *= 2;
    return snapshot + cast(ulong) view.width * view.height * 4;
}

private struct ChangedRows
{
    size_t first;
    size_t count;
}

// Exact comparison, never a borrowed-address identity or a probabilistic hash.
// On change, update only the span of changed rows; unchanged repaints neither
// copy the pixels nor touch the GPU. Rows stay packed for RGB/gray uploads.
private ChangedRows changedRows(in ubyte[] snapshot, in PixelView view)
    @system nothrow @nogc
{
    assert(snapshot.length == view.pixels.length);
    if (memcmp(snapshot.ptr, view.pixels.ptr, snapshot.length) == 0)
        return ChangedRows.init;
    size_t first;
    size_t end = view.height;
    while (memcmp(snapshot.ptr + first * view.rowBytes,
        view.pixels.ptr + first * view.rowBytes, view.rowBytes) == 0)
        ++first;
    while (end > first + 1 && memcmp(snapshot.ptr + (end - 1) * view.rowBytes,
        view.pixels.ptr + (end - 1) * view.rowBytes, view.rowBytes) == 0)
        --end;
    return ChangedRows(first, end - first);
}

@("terminal_view.kittyImages.exactReplacementAndChangedRows")
@system nothrow @nogc
unittest
{
    ubyte[18] original = 10;
    ubyte[18] current = 10;
    PixelView view = PixelView(2, 3, PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8,
        6, current[]);
    assert(changedRows(original[], view) == ChangedRows(0, 0));
    // Same address/ID/geometry, different contents: never mistake reused image
    // storage for an unchanged upload. Only the middle row needs transfer.
    current[8] = 30;
    assert(changedRows(original[], view) == ChangedRows(1, 1));
    current[17] = 40;
    assert(changedRows(original[], view) == ChangedRows(1, 2));
    current[0] = 50;
    assert(changedRows(original[], view) == ChangedRows(0, 3));
}

@("terminal_view.kittyImages.pixelGeometryAndLayerOrder")
@safe pure nothrow @nogc
unittest
{
    GhosttyKittyGraphicsPlacementRenderInfo info;
    info.viewport_col = 2;
    info.viewport_row = -1;
    info.pixel_width = 17;
    info.pixel_height = 13;
    info.grid_cols = 3;
    info.grid_rows = 2;
    const rect = destinationRect(info, 3, 2, 8, 10);
    assert(rect == Rectangle(19, -8, 17, 13));

    Placement a, b;
    a.z = -1;
    b.z = 0;
    assert(placementBefore(a, b));
    b.z = -1;
    a.imageId = 3;
    b.imageId = 9;
    assert(placementBefore(a, b));
    b.imageId = 3;
    a.placementId = 4;
    b.placementId = 5;
    assert(placementBefore(a, b));
}

@("terminal_view.kittyImages.captureOwnsPixelsAcrossDeletionAndScreenSwitch")
@system nothrow @nogc
unittest
{
    GhosttyTerminal terminal;
    GhosttyTerminalOptions options = { cols: 10, rows: 4 };
    assert(ghostty_terminal_new(null, &terminal, options) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_terminal_free(terminal);
    ulong storage = 1024;
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &storage);
    ghostty_terminal_resize(terminal, 10, 4, 10, 20);
    GhosttyKittyGraphicsPlacementIterator iterator;
    assert(ghostty_kitty_graphics_placement_iterator_new(null, &iterator) == GHOSTTY_SUCCESS);
    scope (exit) ghostty_kitty_graphics_placement_iterator_free(iterator);
    KittyImageRenderer renderer;
    scope (exit) renderer.release();

    static immutable red = "\x1b_Ga=T,f=24,s=1,v=1,i=7,p=3,z=-1,q=2;/wAA\x1b\\";
    ghostty_terminal_vt_write(terminal, cast(const(ubyte)*) red.ptr, red.length);
    renderer.capture(terminal, iterator, 10, 20);
    assert(renderer.capturedImages.length == 1);
    assert(renderer.capturedImages[0].pixels[] == [255, 0, 0]);
    assert(renderer.capturedImages[0].format == PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8);
    assert(renderer.capturedPlacements[0].destination == Rectangle(0, 0, 1, 1));

    static immutable remove = "\x1b_Ga=d,d=I,i=7,q=2\x1b\\";
    ghostty_terminal_vt_write(terminal, cast(const(ubyte)*) remove.ptr, remove.length);
    assert(ghostty_kitty_graphics_image(graphicsFor(terminal), 7) is null);
    assert(renderer.capturedImages[0].pixels[] == [255, 0, 0]);

    static immutable green = "\x1b[?1049h\x1b_Ga=T,f=24,s=1,v=1,i=7,p=3,z=-1,q=2;AP8A\x1b\\";
    ghostty_terminal_vt_write(terminal, cast(const(ubyte)*) green.ptr, green.length);
    // The live alternate-screen image reuses the ID; the held primary-screen
    // picture is still red, with no retained pointer into Ghostty's storage.
    assert(renderer.capturedImages[0].pixels[] == [255, 0, 0]);
    renderer.capture(terminal, iterator, 10, 20);
    assert(renderer.capturedImages[0].pixels[] == [0, 255, 0]);
}

@("terminal_view.kittyImages.mutationScannerQueriesAndSplitCommands")
@safe pure nothrow @nogc
unittest
{
    KittyMutationScanner scanner;
    foreach (b; "ordinary text\x1b[31m\x1b]4;1;?\x07\x1b_Ga=q,i=1;AAAA\x1b\\")
        assert(!scanner.scan(b));
    // The prefix/payload/terminator may all straddle different PTY reads.
    foreach (b; "\x1b_Gq=2,a=p,i=1")
        assert(!scanner.scan(b));
    assert(!scanner.scan('\x1b'));
    assert(scanner.scan('\\'));
    foreach (b; "\x1b_Ga=d,d=I,i=1\x1b")
        assert(!scanner.scan(b));
    assert(scanner.scan('\\'));
    foreach (b; "\x1b_Gf=24,s=1,v=1;/wAA\x1b")
        assert(!scanner.scan(b));
    assert(scanner.scan('\\')); // omitted a means transmit
    foreach (b; "\x1b_Ga=p\x18\\")
        assert(!scanner.scan(b)); // cancelled command
}
