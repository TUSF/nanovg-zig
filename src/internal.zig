const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const c = @cImport({
    @cDefine("FONS_NO_STDIO", "1");
    @cInclude("fontstash.h");
    @cDefine("STBI_NO_STDIO", "1");
    @cInclude("stb_image.h");
});

const nvg = @import("nanovg.zig");
const Color = nvg.Color;
const Paint = nvg.Paint;
const Image = nvg.Image;
const ImageFlags = nvg.ImageFlags;
const Font = nvg.Font;

const NVG_INIT_FONTIMAGE_SIZE = 512;
const NVG_MAX_FONTIMAGE_SIZE = 2048;

// Length proportional to radius of a cubic bezier handle for 90deg arcs.
const kappa90 = 4.0 * (@sqrt(2.0) - 1.0) / 3.0; // 0.5522847493

pub const Context = struct {
    allocator: Allocator,
    params: Params,
    commands: ArrayList(f32),
    commandx: f32 = 0,
    commandy: f32 = 0,
    states: ArrayList(State),
    cache: PathCache,
    tess_tol: f32,
    dist_tol: f32,
    fringe_width: f32,
    device_px_ratio: f32 = 1,
    fs: ?*c.FONScontext = null,
    font_images: [4]i32 = [_]i32{0} ** 4,
    font_image_idx: u32 = 0,
    draw_call_count: u32 = 0,
    fill_tri_count: u32 = 0,
    stroke_tri_count: u32 = 0,
    text_tri_count: u32 = 0,

    pub fn init(allocator: Allocator, params: Params) !*Context {
        var ctx = try allocator.create(Context);
        ctx.* = Context{
            .allocator = allocator,
            .params = params,
            .commands = try ArrayList(f32).initCapacity(allocator, 256),
            .states = try ArrayList(State).initCapacity(allocator, 32),
            .cache = try PathCache.init(allocator),
            .tess_tol = undefined,
            .dist_tol = undefined,
            .fringe_width = undefined,
            .device_px_ratio = undefined,
        };
        errdefer ctx.deinit();

        ctx.save();
        ctx.reset();

        ctx.setDevicePixelRatio(1);

        _ = ctx.params.renderCreate(ctx.params.user_ptr); // TODO: handle error

        var font_params = std.mem.zeroes(c.FONSparams);
        font_params.width = NVG_INIT_FONTIMAGE_SIZE;
        font_params.height = NVG_INIT_FONTIMAGE_SIZE;
        font_params.flags = c.FONS_ZERO_TOPLEFT;
        font_params.renderCreate = null;
        font_params.renderUpdate = null;
        font_params.renderDraw = null;
        font_params.renderDelete = null;
        font_params.userPtr = null;
        ctx.fs = c.fonsCreateInternal(&font_params) orelse return error.CreateFontstashFailed;

        // Create font texture
        ctx.font_images[0] = ctx.params.renderCreateTexture(ctx.params.user_ptr, .alpha, font_params.width, font_params.height, .{}, null);
        if (ctx.font_images[0] == 0) return error.CreateFontTextureFaild;
        ctx.font_image_idx = 0;

        return ctx;
    }

    pub fn deinit(ctx: *Context) void {
        ctx.commands.deinit();
        ctx.states.deinit();
        ctx.cache.deinit();

        if (ctx.fs != null) {
            c.fonsDeleteInternal(ctx.fs);
        }

        for (ctx.font_images) |*font_image| {
            if (font_image.* != 0) {
                ctx.deleteImage(font_image.*);
                font_image.* = 0;
            }
        }

        _ = ctx.params.renderDelete(ctx.params.user_ptr);

        ctx.allocator.destroy(ctx);
    }

    fn setDevicePixelRatio(ctx: *Context, ratio: f32) void {
        ctx.tess_tol = 0.25 / ratio;
        ctx.dist_tol = 0.01 / ratio;
        ctx.fringe_width = 1 / ratio;
        ctx.device_px_ratio = ratio;
    }

    pub fn getState(ctx: *Context) *State {
        return &ctx.states.items[ctx.states.items.len - 1];
    }

    pub fn save(ctx: *Context) void {
        const state = ctx.states.addOne() catch return;
        if (ctx.states.items.len > 1) {
            state.* = ctx.states.items[ctx.states.items.len - 2];
        }
    }

    pub fn restore(ctx: *Context) void {
        _ = ctx.states.popOrNull();
    }

    pub fn reset(ctx: *Context) void {
        var state = ctx.getState();
        state.* = std.mem.zeroes(State);

        setPaintColor(&state.fill, nvg.rgbaf(1, 1, 1, 1));
        setPaintColor(&state.stroke, nvg.rgbaf(0, 0, 0, 1));

        state.composite_operation = nvg.CompositeOperationState.initOperation(.source_over);
        state.shape_antialias = true;
        state.stroke_width = 1;
        state.miter_limit = 10;
        state.line_cap = .butt;
        state.line_join = .miter;
        state.alpha = 1;
        nvg.transformIdentity(&state.xform);

        state.scissor.extent[0] = -1;
        state.scissor.extent[1] = -1;

        state.font_size = 16;
        state.letter_spacing = 0;
        state.line_height = 1;
        state.font_blur = 0;
        state.text_align.horizontal = .left;
        state.text_align.vertical = .baseline;
        state.font_id = c.FONS_INVALID;
    }

    pub fn shapeAntiAlias(ctx: *Context, enabled: bool) void {
        ctx.getState().shape_antialias = enabled;
    }

    pub fn strokeWidth(ctx: *Context, width: f32) void {
        ctx.getState().stroke_width = width;
    }

    pub fn miterLimit(ctx: *Context, limit: f32) void {
        ctx.getState().miter_limit = limit;
    }

    pub fn lineCap(ctx: *Context, cap: nvg.LineCap) void {
        ctx.getState().line_cap = cap;
    }

    pub fn lineJoin(ctx: *Context, join: nvg.LineJoin) void {
        ctx.getState().line_join = join;
    }

    pub fn globalAlpha(ctx: *Context, alpha: f32) void {
        ctx.getState().alpha = alpha;
    }

    pub fn transform(ctx: *Context, a: f32, b: f32, _c: f32, d: f32, e: f32, f: f32) void {
        const state = ctx.getState();
        var t: [6]f32 = .{ a, b, _c, d, e, f };
        nvg.transformPremultiply(&state.xform, &t);
    }

    pub fn resetTransform(ctx: *Context) void {
        const state = ctx.getState();
        nvg.transformIdentity(&state.xform);
    }

    pub fn translate(ctx: *Context, x: f32, y: f32) void {
        const state = ctx.getState();
        var t: [6]f32 = undefined;
        nvg.transformTranslate(&t, x, y);
        nvg.transformPremultiply(&state.xform, &t);
    }

    pub fn rotate(ctx: *Context, angle: f32) void {
        const state = ctx.getState();
        var t: [6]f32 = undefined;
        nvg.transformRotate(&t, angle);
        nvg.transformPremultiply(&state.xform, &t);
    }

    pub fn skewX(ctx: *Context, angle: f32) void {
        const state = ctx.getState();
        var t: [6]f32 = undefined;
        nvg.transformSkewX(&t, angle);
        nvg.transformPremultiply(&state.xform, &t);
    }

    pub fn skewY(ctx: *Context, angle: f32) void {
        const state = ctx.getState();
        var t: [6]f32 = undefined;
        nvg.transformSkewY(&t, angle);
        nvg.transformPremultiply(&state.xform, &t);
    }

    pub fn scale(ctx: *Context, x: f32, y: f32) void {
        const state = ctx.getState();
        var t: [6]f32 = undefined;
        nvg.transformScale(&t, x, y);
        nvg.transformPremultiply(&state.xform, &t);
    }

    pub fn currentTransform(ctx: *Context, xform: *[6]f32) void {
        const state = ctx.getState();
        std.mem.copy(f32, xform, &state.xform);
    }

    pub fn strokeColor(ctx: *Context, color: Color) void {
        const state = ctx.getState();
        setPaintColor(&state.stroke, color);
    }

    pub fn strokePaint(ctx: *Context, paint: Paint) void {
        const state = ctx.getState();
        state.stroke = paint;
        nvg.transformMultiply(&state.stroke.xform, &state.xform);
    }

    pub fn fillColor(ctx: *Context, color: Color) void {
        const state = ctx.getState();
        setPaintColor(&state.fill, color);
    }

    pub fn fillPaint(ctx: *Context, paint: Paint) void {
        const state = ctx.getState();
        state.fill = paint;
        nvg.transformMultiply(&state.fill.xform, &state.xform);
    }

    pub fn createImageMem(ctx: *Context, data: []const u8, flags: ImageFlags) Image {
        var w: c_int = undefined;
        var h: c_int = undefined;
        var n: c_int = undefined;
        const maybe_img = c.stbi_load_from_memory(data.ptr, @intCast(c_int, data.len), &w, &h, &n, 4);
        if (maybe_img) |img| {
            defer c.stbi_image_free(img);
            const size = @intCast(usize, w * h * 4);
            return ctx.createImageRGBA(@intCast(u32, w), @intCast(u32, h), flags, img[0..size]);
        }
        return .{ .handle = 0 };
    }

    pub fn createImageRGBA(ctx: *Context, w: u32, h: u32, flags: ImageFlags, data: []const u8) Image {
        return Image{ .handle = ctx.params.renderCreateTexture(ctx.params.user_ptr, .rgba, @intCast(i32, w), @intCast(i32, h), flags, data.ptr) };
    }

    pub fn createImageAlpha(ctx: *Context, w: u32, h: u32, flags: ImageFlags, data: []const u8) Image {
        return Image{ .handle = ctx.params.renderCreateTexture(ctx.params.user_ptr, .alpha, @intCast(i32, w), @intCast(i32, h), flags, data.ptr) };
    }

    pub fn updateImage(ctx: *Context, image: Image, data: []const u8) void {
        var w: i32 = undefined;
        var h: i32 = undefined;
        _ = ctx.params.renderGetTextureSize(ctx.params.user_ptr, image.handle, &w, &h);
        _ = ctx.params.renderUpdateTexture(ctx.params.user_ptr, image.handle, 0, 0, w, h, data.ptr);
    }

    pub fn beginFrame(ctx: *Context, window_width: f32, window_height: f32, device_pixel_ratio: f32) void {
        ctx.states.clearRetainingCapacity();
        ctx.save();
        ctx.reset();

        ctx.setDevicePixelRatio(device_pixel_ratio);

        ctx.params.renderViewport(ctx.params.user_ptr, window_width, window_height, device_pixel_ratio);

        ctx.draw_call_count = 0;
        ctx.fill_tri_count = 0;
        ctx.stroke_tri_count = 0;
        ctx.text_tri_count = 0;
    }

    pub fn cancelFrame(ctx: *Context) void {
        ctx.params.renderCancel(ctx.params.user_ptr);
    }

    pub fn endFrame(ctx: *Context) void {
        ctx.params.renderFlush(ctx.params.user_ptr);
        if (ctx.font_image_idx != 0) {
            const fontImage = ctx.font_images[ctx.font_image_idx];
            // delete images that smaller than current one
            if (fontImage == 0)
                return;
            var iw: i32 = undefined;
            var ih: i32 = undefined;
            ctx.imageSize(fontImage, &iw, &ih);
            var i: u32 = 0;
            var j: u32 = 0;
            while (i < ctx.font_image_idx) : (i += 1) {
                if (ctx.font_images[i] != 0) {
                    var nw: i32 = undefined;
                    var nh: i32 = undefined;
                    ctx.imageSize(ctx.font_images[i], &nw, &nh);
                    if (nw < iw or nh < ih) {
                        ctx.deleteImage(ctx.font_images[i]);
                    } else {
                        ctx.font_images[j] = ctx.font_images[i];
                        j += 1;
                    }
                }
            }
            // make current font image to first
            ctx.font_images[j] = ctx.font_images[0];
            ctx.font_images[0] = fontImage;
            ctx.font_image_idx = 0;
        }
    }

    pub fn appendCommands(ctx: *Context, vals: []f32) void {
        const state = ctx.getState();

        ctx.commands.ensureUnusedCapacity(vals.len) catch return;

        if (Command.fromValue(vals[0]) != .close and Command.fromValue(vals[0]) != .winding) {
            ctx.commandx = vals[vals.len - 2];
            ctx.commandy = vals[vals.len - 1];
        }

        // transform commands
        var i: u32 = 0;
        while (i < vals.len) {
            switch (Command.fromValue(vals[i])) {
                .move_to => {
                    transformPoint(&vals[i + 1], &vals[i + 2], state.xform, vals[i + 1], vals[i + 2]);
                    i += 3;
                },
                .line_to => {
                    transformPoint(&vals[i + 1], &vals[i + 2], state.xform, vals[i + 1], vals[i + 2]);
                    i += 3;
                },
                .bezier_to => {
                    transformPoint(&vals[i + 1], &vals[i + 2], state.xform, vals[i + 1], vals[i + 2]);
                    transformPoint(&vals[i + 3], &vals[i + 4], state.xform, vals[i + 3], vals[i + 4]);
                    transformPoint(&vals[i + 5], &vals[i + 6], state.xform, vals[i + 5], vals[i + 6]);
                    i += 7;
                },
                .close => i += 1,
                .winding => i += 2,
            }
        }

        ctx.commands.appendSliceAssumeCapacity(vals);
    }

    fn tesselateBezier(ctx: *Context, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, x4: f32, y4: f32, level: u8, cornerType: PointFlag) void {
        if (level > 10) return;

        const x12 = (x1 + x2) * 0.5;
        const y12 = (y1 + y2) * 0.5;
        const x23 = (x2 + x3) * 0.5;
        const y23 = (y2 + y3) * 0.5;
        const x34 = (x3 + x4) * 0.5;
        const y34 = (y3 + y4) * 0.5;
        const x123 = (x12 + x23) * 0.5;
        const y123 = (y12 + y23) * 0.5;

        const dx = x4 - x1;
        const dy = y4 - y1;

        const d2 = @fabs(((x2 - x4) * dy - (y2 - y4) * dx));
        const d3 = @fabs(((x3 - x4) * dy - (y3 - y4) * dx));

        if ((d2 + d3) * (d2 + d3) < ctx.tess_tol * (dx * dx + dy * dy)) {
            ctx.cache.addPoint(x4, y4, cornerType, ctx.dist_tol);
            return;
        }

        const x234 = (x23 + x34) * 0.5;
        const y234 = (y23 + y34) * 0.5;
        const x1234 = (x123 + x234) * 0.5;
        const y1234 = (y123 + y234) * 0.5;

        ctx.tesselateBezier(x1, y1, x12, y12, x123, y123, x1234, y1234, level + 1, .none);
        ctx.tesselateBezier(x1234, y1234, x234, y234, x34, y34, x4, y4, level + 1, cornerType);
    }

    fn flattenPaths(ctx: *Context) void {
        const cache = &ctx.cache;

        if (cache.paths.items.len > 0)
            return;

        // Flatten
        var i: u32 = 0;
        while (i < ctx.commands.items.len) {
            switch (Command.fromValue(ctx.commands.items[i])) {
                .move_to => {
                    cache.addPath();
                    const p = ctx.commands.items[i + 1 ..];
                    cache.addPoint(p[0], p[1], .corner, ctx.dist_tol);
                    i += 3;
                },
                .line_to => {
                    const p = ctx.commands.items[i + 1 ..];
                    cache.addPoint(p[0], p[1], .corner, ctx.dist_tol);
                    i += 3;
                },
                .bezier_to => {
                    if (cache.lastPoint()) |last| {
                        const cp1 = ctx.commands.items[i + 1 ..];
                        const cp2 = ctx.commands.items[i + 3 ..];
                        const p = ctx.commands.items[i + 5 ..];
                        ctx.tesselateBezier(last.x, last.y, cp1[0], cp1[1], cp2[0], cp2[1], p[0], p[1], 0, .corner);
                    }
                    i += 7;
                },
                .close => {
                    cache.closePath();
                    i += 1;
                },
                .winding => {
                    cache.pathWinding(@intToEnum(nvg.Winding, @floatToInt(u2, ctx.commands.items[i + 1])));
                    i += 2;
                },
            }
        }

        cache.bounds[0] = 1e6;
        cache.bounds[1] = 1e6;
        cache.bounds[2] = -1e6;
        cache.bounds[3] = -1e6;

        // Calculate the direction and length of line segments.
        for (cache.paths.items) |*path| {
            var pts = cache.points.items[path.first..][0..path.count];

            // If the first and last points are the same, remove the last, mark as closed path.
            var p0 = &pts[pts.len - 1];
            if (ptEquals(p0.x, p0.y, pts[0].x, pts[0].y, ctx.dist_tol)) {
                path.count -= 1;
                pts.len -= 1;
                path.closed = true;
            }

            // Enforce winding.
            if (path.count > 2) {
                const area = polyArea(pts);
                if (path.winding == .ccw and area < 0.0)
                    polyReverse(pts);
                if (path.winding == .cw and area > 0.0)
                    polyReverse(pts);
            }

            p0 = &pts[pts.len - 1];
            for (pts) |*p1| {
                defer p0 = p1;
                // Calculate segment direction and length
                p0.dx = p1.x - p0.x;
                p0.dy = p1.y - p0.y;
                p0.len = normalize(&p0.dx, &p0.dy);
                // Update bounds
                cache.bounds[0] = std.math.min(cache.bounds[0], p0.x);
                cache.bounds[1] = std.math.min(cache.bounds[1], p0.y);
                cache.bounds[2] = std.math.max(cache.bounds[2], p0.x);
                cache.bounds[3] = std.math.max(cache.bounds[3], p0.y);
            }
        }
    }

    fn calculateJoins(ctx: *Context, w: f32, line_join: nvg.LineJoin, miter_limit: f32) void {
        const cache = &ctx.cache;
        var iw: f32 = 0.0;
        if (w > 0.0) iw = 1.0 / w;

        // Calculate which joins needs extra vertices to append, and gather vertex count.
        for (cache.paths.items) |*path| {
            const pts = cache.points.items[path.first..][0..path.count];
            var nleft: u32 = 0;
            path.nbevel = 0;

            var p0 = &pts[pts.len - 1];
            for (pts) |*p1| {
                defer p0 = p1;

                const dlx0 = p0.dy;
                const dly0 = -p0.dx;
                const dlx1 = p1.dy;
                const dly1 = -p1.dx;
                // Calculate extrusions
                p1.dmx = (dlx0 + dlx1) * 0.5;
                p1.dmy = (dly0 + dly1) * 0.5;
                const dmr2 = p1.dmx * p1.dmx + p1.dmy * p1.dmy;
                if (dmr2 > 0.000001) {
                    var s = 1.0 / dmr2;
                    if (s > 600) {
                        s = 600;
                    }
                    p1.dmx *= s;
                    p1.dmy *= s;
                }

                // Clear flags, but keep the corner.
                p1.flags = if ((p1.flags & @enumToInt(PointFlag.corner)) != 0) @enumToInt(PointFlag.corner) else 0;

                // Keep track of left turns.
                if (cross(p0.dx, p0.dy, p1.dx, p1.dy) > 0.0) {
                    nleft += 1;
                    p1.flags |= @enumToInt(PointFlag.left);
                }

                // Calculate if we should use bevel or miter for inner join.
                const limit = std.math.max(1.01, std.math.min(p0.len, p1.len) * iw);
                if ((dmr2 * limit * limit) < 1.0)
                    p1.flags |= @enumToInt(PointFlag.innerbevel);

                // Check to see if the corner needs to be beveled.
                if ((p1.flags & @enumToInt(PointFlag.corner)) != 0) {
                    if ((dmr2 * miter_limit * miter_limit) < 1.0 or line_join == .bevel or line_join == .round) {
                        p1.flags |= @enumToInt(PointFlag.bevel);
                    }
                }

                if ((p1.flags & (@enumToInt(PointFlag.bevel) | @enumToInt(PointFlag.innerbevel))) != 0)
                    path.nbevel += 1;
            }

            path.convex = (nleft == path.count);
        }
    }

    fn expandFill(ctx: *Context, w: f32, line_join: nvg.LineJoin, miter_limit: f32) i32 {
        const cache = &ctx.cache;
        const aa = ctx.fringe_width;
        const fringe = w > 0.0;

        ctx.calculateJoins(w, line_join, miter_limit);

        // Calculate max vertex usage.
        var cverts: u32 = 0;
        for (cache.paths.items) |path| {
            cverts += path.count + path.nbevel + 1;
            if (fringe)
                cverts += (path.count + path.nbevel * 5 + 1) * 2; // plus one for loop
        }

        var verts = cache.allocTempVerts(cverts) orelse return 0;

        const convex = cache.paths.items.len == 1 and cache.paths.items[0].convex;

        for (cache.paths.items) |*path| {
            const pts = cache.points.items[path.first..][0..path.count];

            // Calculate shape vertices.
            const woff = 0.5 * aa;
            var dst = verts;
            var dst_i: u32 = 0;
            path.fill = dst;

            if (fringe) {
                // Looping
                var p0 = &pts[pts.len - 1];
                for (pts) |*p1| {
                    defer p0 = p1;
                    if ((p1.flags & @enumToInt(PointFlag.bevel)) != 0) {
                        const dlx0 = p0.dy;
                        const dly0 = -p0.dx;
                        const dlx1 = p1.dy;
                        const dly1 = -p1.dx;
                        if ((p1.flags & @enumToInt(PointFlag.left)) != 0) {
                            const lx = p1.x + p1.dmx * woff;
                            const ly = p1.y + p1.dmy * woff;
                            dst[dst_i].set(lx, ly, 0.5, 1);
                            dst_i += 1;
                        } else {
                            const lx0 = p1.x + dlx0 * woff;
                            const ly0 = p1.y + dly0 * woff;
                            const lx1 = p1.x + dlx1 * woff;
                            const ly1 = p1.y + dly1 * woff;
                            dst[dst_i].set(lx0, ly0, 0.5, 1);
                            dst_i += 1;
                            dst[dst_i].set(lx1, ly1, 0.5, 1);
                            dst_i += 1;
                        }
                    } else {
                        dst[dst_i].set(p1.x + (p1.dmx * woff), p1.y + (p1.dmy * woff), 0.5, 1);
                        dst_i += 1;
                    }
                }
            } else {
                for (pts) |p| {
                    dst[dst_i].set(p.x, p.y, 0.5, 1);
                    dst_i += 1;
                }
            }

            path.nfill = dst_i;
            verts = dst[dst_i..verts.len];

            // Calculate fringe
            if (fringe) {
                var lw = w + woff;
                var rw = w - woff;
                var lu: f32 = 0;
                var ru: f32 = 1;
                dst = verts;
                dst_i = 0;
                path.stroke = dst;

                // Create only half a fringe for convex shapes so that
                // the shape can be rendered without stenciling.
                if (convex) {
                    lw = woff; // This should generate the same vertex as fill inset above.
                    lu = 0.5; // Set outline fade at middle.
                }

                // Looping
                var p0 = &pts[pts.len - 1];
                for (pts) |*p1| {
                    defer p0 = p1;
                    if ((p1.flags & (@enumToInt(PointFlag.bevel) | @enumToInt(PointFlag.innerbevel))) != 0) {
                        dst_i += bevelJoin(dst[dst_i..], p0.*, p1.*, lw, rw, lu, ru, ctx.fringe_width);
                    } else {
                        dst[dst_i].set(p1.x + (p1.dmx * lw), p1.y + (p1.dmy * lw), lu, 1);
                        dst_i += 1;
                        dst[dst_i].set(p1.x - (p1.dmx * rw), p1.y - (p1.dmy * rw), ru, 1);
                        dst_i += 1;
                    }
                }

                // Loop it
                dst[dst_i].set(verts[0].x, verts[0].y, lu, 1);
                dst_i += 1;
                dst[dst_i].set(verts[1].x, verts[1].y, ru, 1);
                dst_i += 1;

                path.nstroke = dst_i;
                verts = dst[dst_i..verts.len];
            } else {
                path.stroke = &.{};
                path.nstroke = 0;
            }
        }

        return 1;
    }

    pub fn expandStroke(ctx: *Context, width: f32, fringe: f32, line_cap: nvg.LineCap, line_join: nvg.LineJoin, miter_limit: f32) i32 {
        const cache = &ctx.cache;
        const aa = fringe;
        var @"u0": f32 = 0;
        var @"u1": f32 = 1;
        var w = width;
        const ncap = curveDivs(w, std.math.pi, ctx.tess_tol); // Calculate divisions per half circle.

        w += aa * 0.5;

        // Disable the gradient used for antialiasing when antialiasing is not used.
        if (aa == 0) {
            @"u0" = 0.5;
            @"u1" = 0.5;
        }

        ctx.calculateJoins(w, line_join, miter_limit);

        // Calculate max vertex usage.
        var cverts: u32 = 0;
        for (cache.paths.items) |path| {
            const loop = path.closed;
            if (line_join == .round) {
                cverts += (path.count + path.nbevel * (ncap + 2) + 1) * 2; // plus one for loop
            } else {
                cverts += (path.count + path.nbevel * 5 + 1) * 2; // plus one for loop
            }
            if (!loop) {
                // space for caps
                if (line_cap == .round) {
                    cverts += (ncap * 2 + 2) * 2;
                } else {
                    cverts += (3 + 3) * 2;
                }
            }
        }

        var verts = cache.allocTempVerts(cverts) orelse return 0;

        for (cache.paths.items) |*path| {
            const pts = cache.points.items[path.first..][0..path.count];

            path.fill = &.{};
            path.nfill = 0;

            // Calculate fringe or stroke
            const loop = path.closed;
            var dst = verts;
            var dst_i: u32 = 0;
            path.stroke = dst;

            var p0 = &pts[path.count - 1];
            var p1 = &pts[0];
            var s: u32 = 0;
            var e = path.count;
            if (loop) {
                // Looping
                p0 = &pts[path.count - 1];
                p1 = &pts[0];
                s = 0;
                e = path.count;
            } else {
                // Add cap
                p0 = &pts[0];
                p1 = &pts[1];
                s = 1;
                e = path.count - 1;
            }

            if (!loop) {
                // Add cap
                var dx = p1.x - p0.x;
                var dy = p1.y - p0.y;
                _ = normalize(&dx, &dy);
                dst_i += switch (line_cap) {
                    .butt => buttCapStart(dst[dst_i..], p0.*, dx, dy, w, -aa * 0.5, aa, @"u0", @"u1"),
                    .square => buttCapStart(dst[dst_i..], p0.*, dx, dy, w, w - aa, aa, @"u0", @"u1"),
                    .round => roundCapStart(dst[dst_i..], p0.*, dx, dy, w, ncap, aa, @"u0", @"u1"),
                };
            }

            var j: u32 = s;
            while (j < e) : (j += 1) {
                p1 = &pts[j];
                if ((p1.flags & (@enumToInt(PointFlag.bevel) | @enumToInt(PointFlag.innerbevel))) != 0) {
                    if (line_join == .round) {
                        dst_i += roundJoin(dst[dst_i..], p0.*, p1.*, w, w, @"u0", @"u1", ncap, aa);
                    } else {
                        dst_i += bevelJoin(dst[dst_i..], p0.*, p1.*, w, w, @"u0", @"u1", aa);
                    }
                } else {
                    dst[dst_i].set(p1.x + (p1.dmx * w), p1.y + (p1.dmy * w), @"u0", 1);
                    dst_i += 1;
                    dst[dst_i].set(p1.x - (p1.dmx * w), p1.y - (p1.dmy * w), @"u1", 1);
                    dst_i += 1;
                }
                p0 = p1;
            }

            if (loop) {
                // Loop it
                dst[dst_i].set(verts[0].x, verts[0].y, @"u0", 1);
                dst_i += 1;
                dst[dst_i].set(verts[1].x, verts[1].y, @"u1", 1);
                dst_i += 1;
            } else {
                p1 = &pts[j];
                // Add cap
                var dx = p1.x - p0.x;
                var dy = p1.y - p0.y;
                _ = normalize(&dx, &dy);

                dst_i += switch (line_cap) {
                    .butt => buttCapEnd(dst[dst_i..], p1.*, dx, dy, w, -aa * 0.5, aa, @"u0", @"u1"),
                    .square => buttCapEnd(dst[dst_i..], p1.*, dx, dy, w, w - aa, aa, @"u0", @"u1"),
                    .round => roundCapEnd(dst[dst_i..], p1.*, dx, dy, w, ncap, aa, @"u0", @"u1"),
                };
            }

            path.nstroke = dst_i;
            verts = dst[dst_i..verts.len];
        }

        return 1;
    }

    pub fn beginPath(ctx: *Context) void {
        ctx.commands.clearRetainingCapacity();
        ctx.cache.clear();
    }

    pub fn moveTo(ctx: *Context, x: f32, y: f32) void {
        ctx.appendCommands(&.{ Command.move_to.toValue(), x, y });
    }

    pub fn lineTo(ctx: *Context, x: f32, y: f32) void {
        ctx.appendCommands(&.{ Command.line_to.toValue(), x, y });
    }

    pub fn bezierTo(ctx: *Context, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
        ctx.appendCommands(&.{ Command.bezier_to.toValue(), c1x, c1y, c2x, c2y, x, y });
    }

    pub fn quadTo(ctx: *Context, cx: f32, cy: f32, x: f32, y: f32) void {
        const x0 = ctx.commandx;
        const y0 = ctx.commandy;
        // zig fmt: off
        ctx.appendCommands(&.{
            Command.bezier_to.toValue(),
            x0 + 2.0/3.0*(cx - x0), y0 + 2.0/3.0*(cy - y0),
            x + 2.0/3.0*(cx - x), y + 2.0/3.0*(cy - y),
            x, y
        });
        // zig fmt: on
    }

    pub fn arcTo(ctx: *Context, x1: f32, y1: f32, x2: f32, y2: f32, radius: f32) void {
        const x0: f32 = ctx.commandx;
        const y0: f32 = ctx.commandy;

        if (ctx.commands.items.len == 0) {
            return;
        }

        // Handle degenerate cases.
        if (ptEquals(x0, y0, x1, y1, ctx.dist_tol) or
            ptEquals(x1, y1, x2, y2, ctx.dist_tol) or
            distPtSeg(x1, y1, x0, y0, x2, y2) < ctx.dist_tol * ctx.dist_tol or
            radius < ctx.dist_tol)
        {
            ctx.lineTo(x1, y1);
            return;
        }

        // Calculate tangential circle to lines (x0,y0)-(x1,y1) and (x1,y1)-(x2,y2).
        var dx0 = x0 - x1;
        var dy0 = y0 - y1;
        var dx1 = x2 - x1;
        var dy1 = y2 - y1;
        _ = normalize(&dx0, &dy0);
        _ = normalize(&dx1, &dy1);
        const a = std.math.acos(dx0 * dx1 + dy0 * dy1);
        const d = radius / std.math.tan(a / 2.0);
        if (d > 10000.0) {
            ctx.lineTo(x1, y1);
            return;
        }

        if (cross(dx0, dy0, dx1, dy1) > 0.0) {
            ctx.arc(
                x1 + dx0 * d + dy0 * radius,
                y1 + dy0 * d + -dx0 * radius,
                radius,
                std.math.atan2(f32, dx0, -dy0),
                std.math.atan2(f32, -dx1, dy1),
                .cw,
            );
        } else {
            ctx.arc(
                x1 + dx0 * d + -dy0 * radius,
                y1 + dy0 * d + dx0 * radius,
                radius,
                std.math.atan2(f32, -dx0, dy0),
                std.math.atan2(f32, dx1, -dy1),
                .ccw,
            );
        }
    }

    pub fn closePath(ctx: *Context) void {
        ctx.appendCommands(&.{Command.close.toValue()});
    }

    pub fn pathWinding(ctx: *Context, dir: nvg.Winding) void {
        ctx.appendCommands(&.{ Command.winding.toValue(), @intToFloat(f32, @enumToInt(dir)) });
    }

    pub fn arc(ctx: *Context, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, dir: nvg.Winding) void {
        const move: Command = if (ctx.commands.items.len > 0) .line_to else .move_to;

        // Clamp angles
        var da = a1 - a0;
        if (dir == .cw) {
            if (@fabs(da) >= std.math.pi * 2.0) {
                da = std.math.pi * 2.0;
            } else {
                while (da < 0.0) da += std.math.pi * 2.0;
            }
        } else {
            if (@fabs(da) >= std.math.pi * 2.0) {
                da = -std.math.pi * 2.0;
            } else {
                while (da > 0.0) da -= std.math.pi * 2.0;
            }
        }

        // Split arc into max 90 degree segments.
        const ndivs = std.math.clamp(@round(@fabs(da) / (std.math.pi * 0.5)), 1, 5);
        const hda = (da / ndivs) / 2.0;
        var kappa = @fabs(4.0 / 3.0 * (1.0 - @cos(hda)) / @sin(hda));

        if (dir == .ccw)
            kappa = -kappa;

        var px: f32 = 0;
        var py: f32 = 0;
        var ptanx: f32 = 0;
        var ptany: f32 = 0;
        var i: f32 = 0;
        while (i <= ndivs) : (i += 1) {
            const a = a0 + da * (i / ndivs);
            const dx = @cos(a);
            const dy = @sin(a);
            const x = cx + dx * r;
            const y = cy + dy * r;
            const tanx = -dy * r * kappa;
            const tany = dx * r * kappa;

            if (i == 0) {
                ctx.appendCommands(&.{ move.toValue(), x, y });
            } else {
                ctx.appendCommands(&.{ Command.bezier_to.toValue(), px + ptanx, py + ptany, x - tanx, y - tany, x, y });
            }
            px = x;
            py = y;
            ptanx = tanx;
            ptany = tany;
        }
    }

    pub fn rect(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
        ctx.appendCommands(&.{
            Command.move_to.toValue(), x,     y,
            Command.line_to.toValue(), x,     y + h,
            Command.line_to.toValue(), x + w, y + h,
            Command.line_to.toValue(), x + w, y,
            Command.close.toValue(),
        });
    }

    pub fn roundedRect(ctx: *Context, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        ctx.roundedRectVarying(x, y, w, h, r, r, r, r);
    }

    pub fn roundedRectVarying(ctx: *Context, x: f32, y: f32, w: f32, h: f32, radTopLeft: f32, radTopRight: f32, radBottomRight: f32, radBottomLeft: f32) void {
        if (radTopLeft < 0.1 and radTopRight < 0.1 and radBottomRight < 0.1 and radBottomLeft < 0.1) {
            ctx.rect(x, y, w, h);
        } else {
            const halfw = @fabs(w) * 0.5;
            const halfh = @fabs(h) * 0.5;
            const rxBL = std.math.min(radBottomLeft, halfw) * sign(w);
            const ryBL = std.math.min(radBottomLeft, halfh) * sign(h);
            const rxBR = std.math.min(radBottomRight, halfw) * sign(w);
            const ryBR = std.math.min(radBottomRight, halfh) * sign(h);
            const rxTR = std.math.min(radTopRight, halfw) * sign(w);
            const ryTR = std.math.min(radTopRight, halfh) * sign(h);
            const rxTL = std.math.min(radTopLeft, halfw) * sign(w);
            const ryTL = std.math.min(radTopLeft, halfh) * sign(h);
            // zig fmt: off
            ctx.appendCommands(&.{
                Command.move_to.toValue(), x, y + ryTL,
                Command.line_to.toValue(), x, y + h - ryBL,
                Command.bezier_to.toValue(), x, y + h - ryBL*(1 - kappa90), x + rxBL*(1 - kappa90), y + h, x + rxBL, y + h,
                Command.line_to.toValue(), x + w - rxBR, y + h,
                Command.bezier_to.toValue(), x + w - rxBR*(1 - kappa90), y + h, x + w, y + h - ryBR*(1 - kappa90), x + w, y + h - ryBR,
                Command.line_to.toValue(), x + w, y + ryTR,
                Command.bezier_to.toValue(), x + w, y + ryTR*(1 - kappa90), x + w - rxTR*(1 - kappa90), y, x + w - rxTR, y,
                Command.line_to.toValue(), x + rxTL, y,
                Command.bezier_to.toValue(), x + rxTL*(1 - kappa90), y, x, y + ryTL*(1 - kappa90), x, y + ryTL,
                Command.close.toValue(),
            });
            // zig fmt: on
        }
    }

    pub fn ellipse(ctx: *Context, cx: f32, cy: f32, rx: f32, ry: f32) void {
        // zig fmt: off
        ctx.appendCommands(&.{
            Command.move_to.toValue(), cx-rx, cy,
            Command.bezier_to.toValue(), cx-rx, cy+ry*kappa90, cx-rx*kappa90, cy+ry, cx, cy+ry,
            Command.bezier_to.toValue(), cx+rx*kappa90, cy+ry, cx+rx, cy+ry*kappa90, cx+rx, cy,
            Command.bezier_to.toValue(), cx+rx, cy-ry*kappa90, cx+rx*kappa90, cy-ry, cx, cy-ry,
            Command.bezier_to.toValue(), cx-rx*kappa90, cy-ry, cx-rx, cy-ry*kappa90, cx-rx, cy,
            Command.close.toValue(),
        });
        // zig fmt: on
    }

    pub fn circle(ctx: *Context, cx: f32, cy: f32, r: f32) void {
        ctx.ellipse(cx, cy, r, r);
    }

    pub fn imageSize(ctx: *Context, image: i32, w: *i32, h: *i32) void {
        _ = ctx.params.renderGetTextureSize(ctx.params.user_ptr, image, w, h);
    }

    pub fn deleteImage(ctx: *Context, image: i32) void {
        _ = ctx.params.renderDeleteTexture(ctx.params.user_ptr, image);
    }

    pub fn linearGradient(ctx: *Context, sx: f32, sy: f32, ex: f32, ey: f32, icol: Color, ocol: Color) Paint {
        _ = ctx;
        var p = std.mem.zeroes(Paint);
        const large = 1e5;

        // Calculate transform aligned to the line
        var dx = ex - sx;
        var dy = ey - sy;
        const d = @sqrt(dx * dx + dy * dy);
        if (d > 0.0001) {
            dx /= d;
            dy /= d;
        } else {
            dx = 0;
            dy = 1;
        }

        p.xform[0] = dy;
        p.xform[1] = -dx;
        p.xform[2] = dx;
        p.xform[3] = dy;
        p.xform[4] = sx - dx * large;
        p.xform[5] = sy - dy * large;

        p.extent[0] = large;
        p.extent[1] = large + d * 0.5;

        p.radius = 0;

        p.feather = std.math.max(1, d);

        p.inner_color = icol;
        p.outer_color = ocol;

        return p;
    }

    pub fn radialGradient(ctx: *Context, cx: f32, cy: f32, inr: f32, outr: f32, icol: Color, ocol: Color) Paint {
        _ = ctx;
        const r = (inr + outr) * 0.5;
        const f = (outr - inr);
        var p = std.mem.zeroes(Paint);

        nvg.transformIdentity(&p.xform);
        p.xform[4] = cx;
        p.xform[5] = cy;

        p.extent[0] = r;
        p.extent[1] = r;

        p.radius = r;

        p.feather = std.math.max(1, f);

        p.inner_color = icol;
        p.outer_color = ocol;

        return p;
    }

    pub fn boxGradient(ctx: *Context, x: f32, y: f32, w: f32, h: f32, r: f32, f: f32, icol: Color, ocol: Color) Paint {
        _ = ctx;
        var p = std.mem.zeroes(Paint);

        nvg.transformIdentity(&p.xform);
        p.xform[4] = x + w * 0.5;
        p.xform[5] = y + h * 0.5;

        p.extent[0] = w * 0.5;
        p.extent[1] = h * 0.5;

        p.radius = r;

        p.feather = std.math.max(1, f);

        p.inner_color = icol;
        p.outer_color = ocol;

        return p;
    }

    pub fn imagePattern(ctx: *Context, ox: f32, oy: f32, ex: f32, ey: f32, angle: f32, image: Image, alpha: f32) nvg.Paint {
        _ = ctx;
        var p: Paint = std.mem.zeroes(Paint);

        nvg.transformRotate(&p.xform, angle);
        p.xform[4] = ox;
        p.xform[5] = oy;

        p.extent[0] = ex;
        p.extent[1] = ey;

        p.image = image;

        p.inner_color = nvg.rgbaf(1, 1, 1, alpha);
        p.outer_color = nvg.rgbaf(1, 1, 1, alpha);

        return p;
    }

    pub fn indexedImagePattern(ctx: *Context, ox: f32, oy: f32, ex: f32, ey: f32, angle: f32, image: Image, colormap: Image, alpha: f32) Paint {
        _ = ctx;
        var p: Paint = std.mem.zeroes(Paint);

        nvg.transformRotate(&p.xform, angle);
        p.xform[4] = ox;
        p.xform[5] = oy;

        p.extent[0] = ex;
        p.extent[1] = ey;

        p.image = image;
        p.colormap = colormap;

        p.inner_color = nvg.rgbaf(1, 1, 1, alpha);
        p.outer_color = nvg.rgbaf(1, 1, 1, alpha);

        return p;
    }

    pub fn scissor(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
        const state = ctx.getState();

        nvg.transformIdentity(&state.scissor.xform);
        state.scissor.xform[4] = x + w * 0.5;
        state.scissor.xform[5] = y + h * 0.5;
        nvg.transformMultiply(&state.scissor.xform, &state.xform);

        state.scissor.extent[0] = w * 0.5;
        state.scissor.extent[1] = h * 0.5;
    }

    fn isectRects(dst: *[4]f32, ax: f32, ay: f32, aw: f32, ah: f32, bx: f32, by: f32, bw: f32, bh: f32) void {
        const minx = std.math.max(ax, bx);
        const miny = std.math.max(ay, by);
        const maxx = std.math.min(ax + aw, bx + bw);
        const maxy = std.math.min(ay + ah, by + bh);
        dst[0] = minx;
        dst[1] = miny;
        dst[2] = std.math.max(0, maxx - minx);
        dst[3] = std.math.max(0, maxy - miny);
    }

    pub fn intersectScissor(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
        const state = ctx.getState();

        // If no previous scissor has been set, set the scissor as current scissor.
        if (state.scissor.extent[0] < 0) {
            ctx.scissor(x, y, w, h);
            return;
        }

        // Transform the current scissor rect into current transform space.
        // If there is difference in rotation, this will be approximation.
        const ex = state.scissor.extent[0];
        const ey = state.scissor.extent[1];
        var invxform: [6]f32 = undefined;
        _ = nvg.transformInverse(&invxform, &state.xform);
        var pxform: [6]f32 = state.scissor.xform;
        nvg.transformMultiply(&pxform, &invxform);
        const tex = ex * @fabs(pxform[0]) + ey * @fabs(pxform[2]);
        const tey = ex * @fabs(pxform[1]) + ey * @fabs(pxform[3]);

        // Intersect rects.
        var irect: [4]f32 = undefined;
        isectRects(&irect, pxform[4] - tex, pxform[5] - tey, tex * 2, tey * 2, x, y, w, h);

        ctx.scissor(irect[0], irect[1], irect[2], irect[3]);
    }

    pub fn resetScissor(ctx: *Context) void {
        const state = ctx.getState();
        std.mem.set(f32, &state.scissor.xform, 0);
        state.scissor.extent[0] = -1;
        state.scissor.extent[1] = -1;
    }

    pub fn fill(ctx: *Context) void {
        const state = ctx.getState();
        var fill_paint = state.fill;

        // Apply global alpha
        fill_paint.inner_color.a *= state.alpha;
        fill_paint.outer_color.a *= state.alpha;

        ctx.flattenPaths();

        if (ctx.params.edge_antialias and state.shape_antialias) {
            _ = ctx.expandFill(ctx.fringe_width, .miter, 2.4);
        } else {
            _ = ctx.expandFill(0.0, .miter, 2.4);
        }

        ctx.params.renderFill(ctx.params.user_ptr, &fill_paint, state.composite_operation, &state.scissor, ctx.fringe_width, ctx.cache.bounds, ctx.cache.paths.items);

        // Count triangles
        for (ctx.cache.paths.items) |path| {
            // console.log("{} path nfill={}, nstroke={}", .{i, path.nfill, path.nstroke});
            if (path.nfill >= 2) ctx.fill_tri_count += path.nfill - 2;
            if (path.nstroke >= 2) ctx.fill_tri_count += path.nstroke - 2;
            ctx.draw_call_count += 2;
        }
    }

    pub fn stroke(ctx: *Context) void {
        const state = ctx.getState();
        const s = getAverageScale(state.xform);
        var stroke_width = std.math.clamp(state.stroke_width * s, 0, 200);
        var stroke_paint = state.stroke;

        if (stroke_width < ctx.fringe_width) {
            // If the stroke width is less than pixel size, use alpha to emulate coverage.
            // Since coverage is area, scale by alpha*alpha.
            const alpha = std.math.clamp(stroke_width / ctx.fringe_width, 0, 1);
            stroke_paint.inner_color.a *= alpha * alpha;
            stroke_paint.outer_color.a *= alpha * alpha;
            stroke_width = ctx.fringe_width;
        }

        // Apply global alpha
        stroke_paint.inner_color.a *= state.alpha;
        stroke_paint.outer_color.a *= state.alpha;

        ctx.flattenPaths();

        if (ctx.params.edge_antialias and state.shape_antialias) {
            _ = ctx.expandStroke(stroke_width * 0.5, ctx.fringe_width, state.line_cap, state.line_join, state.miter_limit);
        } else {
            _ = ctx.expandStroke(stroke_width * 0.5, 0, state.line_cap, state.line_join, state.miter_limit);
        }

        ctx.params.renderStroke(ctx.params.user_ptr, &stroke_paint, state.composite_operation, &state.scissor, ctx.fringe_width, stroke_width, ctx.cache.paths.items);

        // Count triangles
        for (ctx.cache.paths.items) |path| {
            if (path.nstroke >= 2) ctx.fill_tri_count += path.nstroke - 2;
            ctx.draw_call_count += 2;
        }
    }

    pub fn createFontMem(ctx: *Context, name: [:0]const u8, data: []const u8) i32 {
        return c.fonsAddFontMem(ctx.fs, name.ptr, @intToPtr([*]u8, @ptrToInt(data.ptr)), @intCast(c_int, data.len), 0, 0);
    }

    pub fn addFallbackFontId(ctx: *Context, base_font: Font, fallback_font: Font) bool {
        if (base_font.handle == -1 or fallback_font.handle == -1) return false;
        return c.fonsAddFallbackFont(ctx.fs, base_font.handle, fallback_font.handle) != 0;
    }

    pub fn fontSize(ctx: *Context, size: f32) void {
        const state = ctx.getState();
        state.font_size = size;
    }

    pub fn fontBlur(ctx: *Context, blur: f32) void {
        const state = ctx.getState();
        state.font_blur = blur;
    }

    pub fn textLetterSpacing(ctx: *Context, spacing: f32) void {
        const state = ctx.getState();
        state.letter_spacing = spacing;
    }

    pub fn textLineHeight(ctx: *Context, line_height: f32) void {
        const state = ctx.getState();
        state.line_height = line_height;
    }

    pub fn textAlign(ctx: *Context, text_align: nvg.TextAlign) void {
        const state = ctx.getState();
        state.text_align = text_align;
    }

    pub fn fontFaceId(ctx: *Context, font: Font) void {
        const state = ctx.getState();
        state.font_id = font.handle;
    }

    pub fn fontFace(ctx: *Context, font: [:0]const u8) void {
        const state = ctx.getState();
        state.font_id = c.fonsGetFontByName(ctx.fs, font.ptr);
    }

    fn flushTextTexture(ctx: Context) void {
        var dirty: [4]i32 = undefined;

        if (c.fonsValidateTexture(ctx.fs, &dirty[0]) != 0) {
            const fontImage = ctx.font_images[ctx.font_image_idx];
            // Update texture
            if (fontImage != 0) {
                var iw: i32 = undefined;
                var ih: i32 = undefined;
                const data = c.fonsGetTextureData(ctx.fs, &iw, &ih);
                const x = dirty[0];
                const y = dirty[1];
                const w = dirty[2] - dirty[0];
                const h = dirty[3] - dirty[1];
                _ = ctx.params.renderUpdateTexture(ctx.params.user_ptr, fontImage, x, y, w, h, data);
            }
        }
    }

    fn allocTextAtlas(ctx: *Context) bool {
        var iw: i32 = undefined;
        var ih: i32 = undefined;
        ctx.flushTextTexture();
        if (ctx.font_image_idx + 1 >= ctx.font_images.len)
            return false;
        // if next fontImage already have a texture
        if (ctx.font_images[ctx.font_image_idx + 1] != 0) {
            ctx.imageSize(ctx.font_images[ctx.font_image_idx + 1], &iw, &ih);
        } else { // calculate the new font image size and create it.
            ctx.imageSize(ctx.font_images[ctx.font_image_idx], &iw, &ih);
            if (iw > ih) {
                ih *= 2;
            } else {
                iw *= 2;
            }
            if (iw > NVG_MAX_FONTIMAGE_SIZE or ih > NVG_MAX_FONTIMAGE_SIZE) {
                iw = NVG_MAX_FONTIMAGE_SIZE;
                ih = NVG_MAX_FONTIMAGE_SIZE;
            }
            ctx.font_images[ctx.font_image_idx + 1] = ctx.params.renderCreateTexture(ctx.params.user_ptr, .alpha, iw, ih, .{}, null);
        }
        ctx.font_image_idx += 1;
        _ = c.fonsResetAtlas(ctx.fs, iw, ih);
        return true;
    }

    fn renderText(ctx: *Context, verts: []Vertex) void {
        const state = ctx.getState();
        var paint = state.fill;

        // Render triangles.
        paint.image.handle = ctx.font_images[ctx.font_image_idx];

        // Apply global alpha
        paint.inner_color.a *= state.alpha;
        paint.outer_color.a *= state.alpha;

        ctx.params.renderTriangles(ctx.params.user_ptr, &paint, state.composite_operation, &state.scissor, ctx.fringe_width, verts);

        ctx.draw_call_count += 1;
        ctx.text_tri_count += @intCast(u32, verts.len) / 3;
    }

    pub fn text(ctx: *Context, x: f32, y: f32, string: []const u8) f32 {
        const state = ctx.getState();
        const s = state.getFontScale() * ctx.device_px_ratio;
        const invs = 1.0 / s;
        const end = &string.ptr[string.len];

        if (state.font_id == c.FONS_INVALID) return x;

        c.fonsSetSize(ctx.fs, state.font_size * s);
        c.fonsSetSpacing(ctx.fs, state.letter_spacing * s);
        c.fonsSetBlur(ctx.fs, state.font_blur * s);
        c.fonsSetAlign(ctx.fs, state.text_align.toInt());
        c.fonsSetFont(ctx.fs, state.font_id);

        const cverts = @intCast(u32, std.math.max(2, string.len) * 6); // conservative estimate.
        var verts = ctx.cache.allocTempVerts(cverts) orelse return x;
        var nverts: u32 = 0;

        var iter: c.FONStextIter = undefined;
        _ = c.fonsTextIterInit(ctx.fs, &iter, x * s, y * s, string.ptr, end, c.FONS_GLYPH_BITMAP_REQUIRED);
        var prevIter = iter;
        var q: c.FONSquad = undefined;
        while (c.fonsTextIterNext(ctx.fs, &iter, &q) != 0) {
            var corners: [4 * 2]f32 = undefined;
            if (iter.prevGlyphIndex == -1) { // can not retrieve glyph?
                if (nverts != 0) {
                    ctx.renderText(verts[0..nverts]);
                    nverts = 0;
                }
                if (!ctx.allocTextAtlas())
                    break; // no memory :(
                iter = prevIter;
                _ = c.fonsTextIterNext(ctx.fs, &iter, &q); // try again
                if (iter.prevGlyphIndex == -1) // still can not find glyph?
                    break;
            }
            prevIter = iter;
            // Transform corners.
            nvg.transformPoint(&corners[0], &corners[1], &state.xform, q.x0 * invs, q.y0 * invs);
            nvg.transformPoint(&corners[2], &corners[3], &state.xform, q.x1 * invs, q.y0 * invs);
            nvg.transformPoint(&corners[4], &corners[5], &state.xform, q.x1 * invs, q.y1 * invs);
            nvg.transformPoint(&corners[6], &corners[7], &state.xform, q.x0 * invs, q.y1 * invs);
            // Create triangles
            if (nverts + 6 <= cverts) {
                verts[nverts].set(corners[0], corners[1], q.s0, q.t0);
                nverts += 1;
                verts[nverts].set(corners[4], corners[5], q.s1, q.t1);
                nverts += 1;
                verts[nverts].set(corners[2], corners[3], q.s1, q.t0);
                nverts += 1;
                verts[nverts].set(corners[0], corners[1], q.s0, q.t0);
                nverts += 1;
                verts[nverts].set(corners[6], corners[7], q.s0, q.t1);
                nverts += 1;
                verts[nverts].set(corners[4], corners[5], q.s1, q.t1);
                nverts += 1;
            }
        }

        // TODO: add back-end bit to do this just once per frame.
        ctx.flushTextTexture();

        ctx.renderText(verts[0..nverts]);

        return iter.nextx / s;
    }

    pub fn textBox(ctx: *Context, x: f32, y: f32, break_row_width: f32, string: []const u8) void {
        const state = ctx.getState();

        if (state.font_id == c.FONS_INVALID) return;

        var lineh: f32 = undefined;
        ctx.textMetrics(null, null, &lineh);

        const oldAlign = state.text_align;
        state.text_align.horizontal = .left;

        var ty = y;
        var rows: [2]nvg.TextRow = undefined;
        var start = string;
        var nrows = ctx.textBreakLines(start, break_row_width, &rows);
        while (nrows != 0) : (nrows = ctx.textBreakLines(start, break_row_width, &rows)) {
            var i: u32 = 0;
            while (i < nrows) : (i += 1) {
                const row = &rows[i];
                const tx = switch (oldAlign.horizontal) {
                    .left => x,
                    .center => x + break_row_width * 0.5,
                    .right => x + break_row_width - row.width,
                    else => x,
                };
                _ = ctx.text(tx, ty, row.text);
                ty += lineh * state.line_height;
            }
            start = rows[nrows - 1].next;
        }

        state.text_align = oldAlign;
    }

    pub fn textGlyphPositions(ctx: *Context, x: f32, y: f32, string: []const u8, positions: []nvg.GlyphPosition) usize {
        const state = ctx.getState();
        const s = state.getFontScale() * ctx.device_px_ratio;
        const invs = 1.0 / s;
        const end = &string.ptr[string.len];

        if (state.font_id == c.FONS_INVALID) return 0;

        c.fonsSetSize(ctx.fs, state.font_size * s);
        c.fonsSetSpacing(ctx.fs, state.letter_spacing * s);
        c.fonsSetBlur(ctx.fs, state.font_blur * s);
        c.fonsSetAlign(ctx.fs, state.text_align.toInt());
        c.fonsSetFont(ctx.fs, state.font_id);

        var npos: usize = 0;
        var iter: c.FONStextIter = undefined;
        _ = c.fonsTextIterInit(ctx.fs, &iter, x * s, y * s, string.ptr, end, c.FONS_GLYPH_BITMAP_OPTIONAL);
        var prevIter = iter;
        var q: c.FONSquad = undefined;
        while (c.fonsTextIterNext(ctx.fs, &iter, &q) != 0) {
            if (iter.prevGlyphIndex < 0 and ctx.allocTextAtlas()) { // can not retrieve glyph?
                iter = prevIter;
                _ = c.fonsTextIterNext(ctx.fs, &iter, &q); // try again
            }
            prevIter = iter;
            positions[npos].str = iter.str;
            positions[npos].x = iter.x * invs;
            positions[npos].minx = std.math.min(iter.x, q.x0) * invs;
            positions[npos].maxx = std.math.max(iter.nextx, q.x1) * invs;
            npos += 1;
            if (npos >= positions.len)
                break;
        }

        return npos;
    }

    const CodePointType = enum {
        space,
        newline,
        char,
        cjk_char,
    };

    pub fn textBreakLines(ctx: *Context, string: []const u8, break_row_width_arg: f32, rows: []nvg.TextRow) usize {
        const state = ctx.getState();
        const s = state.getFontScale() * ctx.device_px_ratio;
        const invs = 1.0 / s;
        const end = &string.ptr[string.len];

        if (rows.len == 0) return 0;
        if (state.font_id == c.FONS_INVALID) return 0;

        if (string.len == 0) return 0;

        c.fonsSetSize(ctx.fs, state.font_size * s);
        c.fonsSetSpacing(ctx.fs, state.letter_spacing * s);
        c.fonsSetBlur(ctx.fs, state.font_blur * s);
        c.fonsSetAlign(ctx.fs, state.text_align.toInt());
        c.fonsSetFont(ctx.fs, state.font_id);

        const break_row_width = break_row_width_arg * s;
        var nrows: usize = 0;
        var pcodepoint: u32 = 0;
        var rowStartX: f32 = 0;
        var rowWidth: f32 = 0;
        var rowMinX: f32 = 0;
        var rowMaxX: f32 = 0;
        var rowStart: ?[*]const u8 = null;
        var rowEnd: ?[*]const u8 = null;
        var wordStart: ?[*]const u8 = null;
        var wordStartX: f32 = 0;
        var wordMinX: f32 = 0;
        var breakEnd: ?[*]const u8 = null;
        var breakWidth: f32 = 0;
        var breakMaxX: f32 = 0;
        var ptype = CodePointType.space;
        var iter: c.FONStextIter = undefined;
        _ = c.fonsTextIterInit(ctx.fs, &iter, 0, 0, string.ptr, end, c.FONS_GLYPH_BITMAP_OPTIONAL);
        var prevIter = iter;
        var q: c.FONSquad = undefined;
        while (c.fonsTextIterNext(ctx.fs, &iter, &q) != 0) {
            if (iter.prevGlyphIndex < 0 and ctx.allocTextAtlas()) { // can not retrieve glyph?
                iter = prevIter;
                _ = c.fonsTextIterNext(ctx.fs, &iter, &q); // try again
            }
            prevIter = iter;
            const ctype = switch (iter.codepoint) {
                9, 11, 12, 32, 0x00a0 => CodePointType.space,
                10 => if (pcodepoint == 13) CodePointType.space else CodePointType.newline,
                13 => if (pcodepoint == 10) CodePointType.space else CodePointType.newline,
                0x0085 => CodePointType.newline,
                else => if ((iter.codepoint >= 0x4E00 and iter.codepoint <= 0x9FFF) or
                    (iter.codepoint >= 0x3000 and iter.codepoint <= 0x30FF) or
                    (iter.codepoint >= 0xFF00 and iter.codepoint <= 0xFFEF) or
                    (iter.codepoint >= 0x1100 and iter.codepoint <= 0x11FF) or
                    (iter.codepoint >= 0x3130 and iter.codepoint <= 0x318F) or
                    (iter.codepoint >= 0xAC00 and iter.codepoint <= 0xD7AF))
                    CodePointType.cjk_char
                else
                    CodePointType.char,
            };

            if (ctype == .newline) {
                // Always handle new lines.
                const start = if (rowStart != null) rowStart else iter.str;
                const e = if (rowEnd != null) rowEnd else iter.str;
                var n = @ptrToInt(e) - @ptrToInt(start);
                rows[nrows].text = start.?[0..n];
                rows[nrows].width = rowWidth * invs;
                rows[nrows].minx = rowMinX * invs;
                rows[nrows].maxx = rowMaxX * invs;
                n = @ptrToInt(end) - @ptrToInt(iter.next);
                rows[nrows].next = iter.next.?[0..n];
                nrows += 1;
                if (nrows >= rows.len)
                    return nrows;
                // Set null break point
                breakEnd = rowStart;
                breakWidth = 0.0;
                breakMaxX = 0.0;
                // Indicate to skip the white space at the beginning of the row.
                rowStart = null;
                rowEnd = null;
                rowWidth = 0;
                rowMinX = 0;
                rowMaxX = 0;
            } else {
                if (rowStart == null) {
                    // Skip white space until the beginning of the line
                    if (ctype == .char or ctype == .cjk_char) {
                        // The current char is the row so far
                        rowStartX = iter.x;
                        rowStart = iter.str;
                        rowEnd = iter.next;
                        rowWidth = iter.nextx - rowStartX;
                        rowMinX = q.x0 - rowStartX;
                        rowMaxX = q.x1 - rowStartX;
                        wordStart = iter.str;
                        wordStartX = iter.x;
                        wordMinX = q.x0 - rowStartX;
                        // Set null break point
                        breakEnd = rowStart;
                        breakWidth = 0.0;
                        breakMaxX = 0.0;
                    }
                } else {
                    const nextWidth = iter.nextx - rowStartX;

                    // track last non-white space character
                    if (ctype == .char or ctype == .cjk_char) {
                        rowEnd = iter.next;
                        rowWidth = iter.nextx - rowStartX;
                        rowMaxX = q.x1 - rowStartX;
                    }
                    // track last end of a word
                    if (((ptype == .char or ptype == .cjk_char) and ctype == .space) or ctype == .cjk_char) {
                        breakEnd = iter.str;
                        breakWidth = rowWidth;
                        breakMaxX = rowMaxX;
                    }
                    // track last beginning of a word
                    if ((ptype == .space and (ctype == .char or ctype == .cjk_char)) or ctype == .cjk_char) {
                        wordStart = iter.str;
                        wordStartX = iter.x;
                        wordMinX = q.x0;
                    }

                    // Break to new line when a character is beyond break width.
                    if ((ctype == .char or ctype == .cjk_char) and nextWidth > break_row_width) {
                        // The run length is too long, need to break to new line.
                        if (breakEnd == rowStart) {
                            // The current word is longer than the row length, just break it from here.
                            var n = @ptrToInt(iter.str) - @ptrToInt(rowStart);
                            rows[nrows].text = rowStart.?[0..n];
                            rows[nrows].width = rowWidth * invs;
                            rows[nrows].minx = rowMinX * invs;
                            rows[nrows].maxx = rowMaxX * invs;
                            n = @ptrToInt(end) - @ptrToInt(iter.str);
                            rows[nrows].next = iter.str.?[0..n];
                            nrows += 1;
                            if (nrows >= rows.len)
                                return nrows;
                            rowStartX = iter.x;
                            rowStart = iter.str;
                            rowEnd = iter.next;
                            rowWidth = iter.nextx - rowStartX;
                            rowMinX = q.x0 - rowStartX;
                            rowMaxX = q.x1 - rowStartX;
                            wordStart = iter.str;
                            wordStartX = iter.x;
                            wordMinX = q.x0 - rowStartX;
                        } else {
                            // Break the line from the end of the last word, and start new line from the beginning of the new.
                            var n = @ptrToInt(breakEnd) - @ptrToInt(rowStart);
                            rows[nrows].text = rowStart.?[0..n];
                            rows[nrows].width = breakWidth * invs;
                            rows[nrows].minx = rowMinX * invs;
                            rows[nrows].maxx = breakMaxX * invs;
                            n = @ptrToInt(end) - @ptrToInt(wordStart);
                            rows[nrows].next = wordStart.?[0..n];
                            nrows += 1;
                            if (nrows >= rows.len)
                                return nrows;
                            // Update row
                            rowStartX = wordStartX;
                            rowStart = wordStart;
                            rowEnd = iter.next;
                            rowWidth = iter.nextx - rowStartX;
                            rowMinX = wordMinX - rowStartX;
                            rowMaxX = q.x1 - rowStartX;
                        }
                        // Set null break point
                        breakEnd = rowStart;
                        breakWidth = 0.0;
                        breakMaxX = 0.0;
                    }
                }
            }

            pcodepoint = iter.codepoint;
            ptype = ctype;
        }

        // Break the line from the end of the last word, and start new line from the beginning of the new.
        if (rowStart != null) {
            var n = @ptrToInt(rowEnd) - @ptrToInt(rowStart);
            rows[nrows].text = rowStart.?[0..n];
            rows[nrows].width = rowWidth * invs;
            rows[nrows].minx = rowMinX * invs;
            rows[nrows].maxx = rowMaxX * invs;
            rows[nrows].next = &.{};
            nrows += 1;
        }

        return nrows;
    }

    pub fn textBounds(ctx: *Context, x: f32, y: f32, string: []const u8, bounds: ?*[4]f32) f32 {
        const state = ctx.getState();
        const s = state.getFontScale() * ctx.device_px_ratio;
        const invs = 1.0 / s;
        const end = &string.ptr[string.len];

        if (state.font_id == c.FONS_INVALID) return 0;

        c.fonsSetSize(ctx.fs, state.font_size * s);
        c.fonsSetSpacing(ctx.fs, state.letter_spacing * s);
        c.fonsSetBlur(ctx.fs, state.font_blur * s);
        c.fonsSetAlign(ctx.fs, state.text_align.toInt());
        c.fonsSetFont(ctx.fs, state.font_id);

        const width = c.fonsTextBounds(ctx.fs, x * s, y * s, string.ptr, end, if (bounds == null) null else &(bounds.?[0]));
        if (bounds) |b| {
            // Use line bounds for height.
            c.fonsLineBounds(ctx.fs, y * s, &b[1], &b[3]);
            b[0] *= invs;
            b[1] *= invs;
            b[2] *= invs;
            b[3] *= invs;
        }
        return width * invs;
    }

    pub fn textBoxBounds(ctx: *Context, x_arg: f32, y_arg: f32, break_row_width: f32, string_arg: []const u8, bounds: ?*[4]f32) void {
        const state = ctx.getState();
        const s = state.getFontScale() * ctx.device_px_ratio;
        const invs = 1.0 / s;

        if (state.font_id == c.FONS_INVALID) {
            if (bounds) |b| {
                b[0] = 0;
                b[1] = 0;
                b[2] = 0;
                b[3] = 0;
            }
            return;
        }

        const oldAlign = state.text_align;
        state.text_align.horizontal = .left;

        var lineh: f32 = undefined;
        ctx.textMetrics(null, null, &lineh);

        c.fonsSetSize(ctx.fs, state.font_size * s);
        c.fonsSetSpacing(ctx.fs, state.letter_spacing * s);
        c.fonsSetBlur(ctx.fs, state.font_blur * s);
        c.fonsSetAlign(ctx.fs, state.text_align.toInt());
        c.fonsSetFont(ctx.fs, state.font_id);
        var rminy: f32 = 0;
        var rmaxy: f32 = 0;
        c.fonsLineBounds(ctx.fs, 0, &rminy, &rmaxy);
        rminy *= invs;
        rmaxy *= invs;

        var x = x_arg;
        var y = y_arg;
        var string = string_arg;

        var minx = x;
        var maxx = x;
        var miny = y;
        var maxy = y;

        var rows: [2]nvg.TextRow = undefined;
        var nrows = ctx.textBreakLines(string, break_row_width, &rows);
        while (nrows != 0) : (nrows = ctx.textBreakLines(string, break_row_width, &rows)) {
            var i: u32 = 0;
            while (i < nrows) : (i += 1) {
                const row = &rows[i];
                // Horizontal bounds
                const dx = switch (oldAlign.horizontal) {
                    .left => 0,
                    .center => break_row_width * 0.5 - row.width * 0.5,
                    .right => break_row_width - row.width,
                    else => 0,
                };
                const rminx = x + row.minx + dx;
                const rmaxx = x + row.maxx + dx;
                minx = std.math.min(minx, rminx);
                maxx = std.math.max(maxx, rmaxx);
                // Vertical bounds.
                miny = std.math.min(miny, y + rminy);
                maxy = std.math.max(maxy, y + rmaxy);

                y += lineh * state.line_height;
            }
            string = rows[nrows - 1].next;
        }

        state.text_align = oldAlign;

        if (bounds) |b| {
            b[0] = minx;
            b[1] = miny;
            b[2] = maxx;
            b[3] = maxy;
        }
    }

    pub fn textMetrics(ctx: *Context, ascender: ?*f32, descender: ?*f32, lineh: ?*f32) void {
        const state = ctx.getState();
        const s = state.getFontScale() * ctx.device_px_ratio;
        const invs = 1.0 / s;

        if (state.font_id == c.FONS_INVALID) return;

        c.fonsSetSize(ctx.fs, state.font_size * s);
        c.fonsSetSpacing(ctx.fs, state.letter_spacing * s);
        c.fonsSetBlur(ctx.fs, state.font_blur * s);
        c.fonsSetAlign(ctx.fs, state.text_align.toInt());
        c.fonsSetFont(ctx.fs, state.font_id);

        c.fonsVertMetrics(ctx.fs, ascender, descender, lineh);
        if (ascender != null)
            ascender.?.* *= invs;
        if (descender != null)
            descender.?.* *= invs;
        if (lineh != null)
            lineh.?.* *= invs;
    }
};

const Command = enum(i32) {
    move_to = 0,
    line_to = 1,
    bezier_to = 2,
    close = 3,
    winding = 4,

    fn fromValue(val: f32) Command {
        return @intToEnum(Command, @floatToInt(i32, val));
    }

    fn toValue(command: Command) f32 {
        return @intToFloat(f32, @enumToInt(command));
    }
};

const PointFlag = enum(u8) {
    none = 0x0,
    corner = 0x01,
    left = 0x02,
    bevel = 0x04,
    innerbevel = 0x08,
};

pub const TextureType = enum(u8) {
    none = 0x0,
    alpha = 0x01,
    rgba = 0x02,
};

pub const Scissor = struct {
    xform: [6]f32,
    extent: [2]f32,
};

pub const Vertex = struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,

    fn set(self: *Vertex, x: f32, y: f32, u: f32, v: f32) void {
        self.x = x;
        self.y = y;
        self.u = u;
        self.v = v;
    }
};

pub const Path = struct {
    first: u32,
    count: u32,
    closed: bool,
    nbevel: u32,
    fill: []Vertex,
    nfill: u32,
    stroke: []Vertex,
    nstroke: u32,
    winding: nvg.Winding,
    convex: bool,
};

pub const Params = struct {
    user_ptr: *anyopaque,
    edge_antialias: bool,
    renderCreate: fn (uptr: *anyopaque) i32,
    renderCreateTexture: fn (uptr: *anyopaque, tex_type: TextureType, w: i32, h: i32, image_flags: ImageFlags, data: ?[*]const u8) i32,
    renderDeleteTexture: fn (uptr: *anyopaque, image: i32) i32,
    renderUpdateTexture: fn (uptr: *anyopaque, image: i32, x: i32, y: i32, w: i32, h: i32, data: ?[*]const u8) i32,
    renderGetTextureSize: fn (uptr: *anyopaque, image: i32, w: *i32, h: *i32) i32,
    renderViewport: fn (uptr: *anyopaque, width: f32, height: f32, device_pixel_ratio: f32) void,
    renderCancel: fn (uptr: *anyopaque) void,
    renderFlush: fn (uptr: *anyopaque) void,
    renderFill: fn (uptr: *anyopaque, paint: *Paint, composite_operation: nvg.CompositeOperationState, scissor: *Scissor, fringe: f32, bounds: [4]f32, paths: []const Path) void,
    renderStroke: fn (uptr: *anyopaque, paint: *Paint, composite_operation: nvg.CompositeOperationState, scissor: *Scissor, fringe: f32, stroke_width: f32, paths: []const Path) void,
    renderTriangles: fn (uptr: *anyopaque, paint: *Paint, composite_operation: nvg.CompositeOperationState, scissor: *Scissor, fringe: f32, verts: []const Vertex) void,
    renderDelete: fn (uptr: *anyopaque) void,
};

const State = struct {
    composite_operation: nvg.CompositeOperationState,
    shape_antialias: bool,
    fill: Paint,
    stroke: Paint,
    stroke_width: f32,
    miter_limit: f32,
    line_join: nvg.LineJoin,
    line_cap: nvg.LineCap,
    alpha: f32,
    xform: [6]f32,
    scissor: Scissor,
    font_size: f32,
    letter_spacing: f32,
    line_height: f32,
    font_blur: f32,
    text_align: nvg.TextAlign,
    font_id: i32,

    fn getFontScale(state: State) f32 {
        return std.math.min(quantize(getAverageScale(state.xform), 0.01), 4.0);
    }
};

const Point = struct {
    x: f32,
    y: f32,
    dx: f32,
    dy: f32,
    len: f32,
    dmx: f32,
    dmy: f32,
    flags: u8,
};

const PathCache = struct {
    allocator: Allocator,
    points: ArrayList(Point),
    paths: ArrayList(Path),
    verts: ArrayList(Vertex),
    bounds: [4]f32 = [_]f32{0} ** 4,

    fn init(allocator: Allocator) !PathCache {
        return PathCache{
            .allocator = allocator,
            .points = try ArrayList(Point).initCapacity(allocator, 128),
            .paths = try ArrayList(Path).initCapacity(allocator, 16),
            .verts = try ArrayList(Vertex).initCapacity(allocator, 256),
        };
    }

    fn deinit(cache: *PathCache) void {
        cache.points.deinit();
        cache.paths.deinit();
        cache.verts.deinit();
    }

    pub fn clear(cache: *PathCache) void {
        cache.points.clearRetainingCapacity();
        cache.paths.clearRetainingCapacity();
    }

    fn allocTempVerts(cache: *PathCache, nverts: u32) ?[]Vertex {
        if (nverts > cache.verts.items.len) {
            const cverts = (nverts + 0xff) & 0xffffff00; // Round up to prevent allocations when things change just slightly.
            cache.verts.ensureTotalCapacity(cverts) catch return null;
            cache.verts.items.len = nverts;
        }

        return cache.verts.items;
    }

    fn lastPath(cache: *PathCache) ?*Path {
        if (cache.paths.items.len > 0)
            return &cache.paths.items[cache.paths.items.len - 1];
        return null;
    }

    fn addPath(cache: *PathCache) void {
        const path = cache.paths.addOne() catch return;
        path.* = std.mem.zeroes(Path);
        path.first = @truncate(u32, cache.points.items.len);
        path.winding = .ccw;
    }

    fn lastPoint(cache: *PathCache) ?*Point {
        if (cache.points.items.len > 0)
            return &cache.points.items[cache.points.items.len - 1];
        return null;
    }

    fn addPoint(cache: *PathCache, x: f32, y: f32, flags: PointFlag, dist_tol: f32) void {
        const path = cache.lastPath() orelse return;

        if (path.count > 0) {
            if (cache.lastPoint()) |pt| {
                if (ptEquals(pt.x, pt.y, x, y, dist_tol)) {
                    pt.flags |= @enumToInt(flags);
                    return;
                }
            }
        }

        const pt = cache.points.addOne() catch return;
        pt.* = std.mem.zeroes(Point);
        pt.x = x;
        pt.y = y;
        pt.flags = @enumToInt(flags);

        path.count += 1;
    }

    fn closePath(cache: *PathCache) void {
        if (cache.lastPath()) |path| {
            path.closed = true;
        }
    }

    fn pathWinding(cache: *PathCache, winding: nvg.Winding) void {
        if (cache.lastPath()) |path| {
            path.winding = winding;
        }
    }
};

fn sign(a: f32) f32 {
    return if (a >= 0) 1 else -1;
}

fn cross(dx0: f32, dy0: f32, dx1: f32, dy1: f32) f32 {
    return dx1 * dy0 - dx0 * dy1;
}

fn normalize(x: *f32, y: *f32) f32 {
    const d = std.math.sqrt((x.*) * (x.*) + (y.*) * (y.*));
    if (d > 1e-6) {
        const id = 1.0 / d;
        x.* *= id;
        y.* *= id;
    }
    return d;
}

fn quantize(a: f32, d: f32) f32 {
    return @round(a / d) * d;
}

fn transformPoint(dx: *f32, dy: *f32, t: [6]f32, sx: f32, sy: f32) void {
    dx.* = sx * t[0] + sy * t[2] + t[4];
    dy.* = sx * t[1] + sy * t[3] + t[5];
}

pub fn setPaintColor(paint: *Paint, color: Color) void {
    paint.* = std.mem.zeroes(Paint);
    nvg.transformIdentity(&paint.xform);
    paint.radius = 0;
    paint.feather = 1;
    paint.inner_color = color;
    paint.outer_color = color;
}

fn ptEquals(x1: f32, y1: f32, x2: f32, y2: f32, tol: f32) bool {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return dx * dx + dy * dy < tol * tol;
}

fn distPtSeg(x: f32, y: f32, px: f32, py: f32, qx: f32, qy: f32) f32 {
    const pqx = qx - px;
    const pqy = qy - py;
    var dx = x - px;
    var dy = y - py;
    const d = pqx * pqx + pqy * pqy;
    var t = pqx * dx + pqy * dy;
    if (d > 0) t /= d;
    t = std.math.clamp(t, 0, 1);
    dx = px + t * pqx - x;
    dy = py + t * pqy - y;
    return dx * dx + dy * dy;
}

fn getAverageScale(t: [6]f32) f32 {
    const sx = @sqrt(t[0] * t[0] + t[2] * t[2]);
    const sy = @sqrt(t[1] * t[1] + t[3] * t[3]);
    return (sx + sy) * 0.5;
}

fn triarea2(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f32 {
    const abx = bx - ax;
    const aby = by - ay;
    const acx = cx - ax;
    const acy = cy - ay;
    return acx * aby - abx * acy;
}

fn polyArea(pts: []Point) f32 {
    var area: f32 = 0;
    var i: u32 = 2;
    while (i < pts.len) : (i += 1) {
        const p0 = pts[0];
        const p1 = pts[i - 1];
        const p2 = pts[i];
        area += triarea2(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y);
    }
    return area * 0.5;
}

fn polyReverse(pts: []Point) void {
    std.mem.reverse(Point, pts);
}

fn curveDivs(r: f32, arc: f32, tol: f32) u32 {
    const da = std.math.acos(r / (r + tol)) * 2;
    return std.math.max(2, @floatToInt(u32, @ceil(arc / da)));
}

fn chooseBevel(bevel: bool, p0: Point, p1: Point, w: f32, x0: *f32, y0: *f32, x1: *f32, y1: *f32) void {
    if (bevel) {
        x0.* = p1.x + p0.dy * w;
        y0.* = p1.y - p0.dx * w;
        x1.* = p1.x + p1.dy * w;
        y1.* = p1.y - p1.dx * w;
    } else {
        x0.* = p1.x + p1.dmx * w;
        y0.* = p1.y + p1.dmy * w;
        x1.* = p1.x + p1.dmx * w;
        y1.* = p1.y + p1.dmy * w;
    }
}

fn roundJoin(dst: []Vertex, p0: Point, p1: Point, lw: f32, rw: f32, lu: f32, ru: f32, ncap: u32, fringe: f32) u32 {
    const dlx0 = p0.dy;
    const dly0 = -p0.dx;
    const dlx1 = p1.dy;
    const dly1 = -p1.dx;
    _ = fringe;
    var dst_i: u32 = 0;

    if ((p1.flags & @enumToInt(PointFlag.left)) != 0) {
        var lx0: f32 = undefined;
        var ly0: f32 = undefined;
        var lx1: f32 = undefined;
        var ly1: f32 = undefined;
        chooseBevel((p1.flags & @enumToInt(PointFlag.innerbevel)) != 0, p0, p1, lw, &lx0, &ly0, &lx1, &ly1);
        var a0 = std.math.atan2(f32, -dly0, -dlx0);
        var a1 = std.math.atan2(f32, -dly1, -dlx1);
        if (a1 > a0) a1 -= std.math.pi * 2.0;

        dst[dst_i].set(lx0, ly0, lu, 1);
        dst_i += 1;
        dst[dst_i].set(p1.x - dlx0 * rw, p1.y - dly0 * rw, ru, 1);
        dst_i += 1;

        const ncapf = @intToFloat(f32, ncap);
        const n = std.math.clamp(@ceil(((a0 - a1) / std.math.pi) * ncapf), 2, ncapf);
        var i: f32 = 0;
        while (i < n) : (i += 1) {
            const u = i / (n - 1);
            const a = a0 + u * (a1 - a0);
            const rx = p1.x + @cos(a) * rw;
            const ry = p1.y + @sin(a) * rw;
            dst[dst_i].set(p1.x, p1.y, 0.5, 1);
            dst_i += 1;
            dst[dst_i].set(rx, ry, ru, 1);
            dst_i += 1;
        }

        dst[dst_i].set(lx1, ly1, lu, 1);
        dst_i += 1;
        dst[dst_i].set(p1.x - dlx1 * rw, p1.y - dly1 * rw, ru, 1);
        dst_i += 1;
    } else {
        var rx0: f32 = undefined;
        var ry0: f32 = undefined;
        var rx1: f32 = undefined;
        var ry1: f32 = undefined;
        chooseBevel((p1.flags & @enumToInt(PointFlag.innerbevel)) != 0, p0, p1, -rw, &rx0, &ry0, &rx1, &ry1);
        var a0 = std.math.atan2(f32, dly0, dlx0);
        var a1 = std.math.atan2(f32, dly1, dlx1);
        if (a1 < a0) a1 += std.math.pi * 2.0;

        dst[dst_i].set(p1.x + dlx0 * rw, p1.y + dly0 * rw, lu, 1);
        dst_i += 1;
        dst[dst_i].set(rx0, ry0, ru, 1);
        dst_i += 1;

        const ncapf = @intToFloat(f32, ncap);
        const n = std.math.clamp(@ceil(((a0 - a1) / std.math.pi) * ncapf), 2, ncapf);
        var i: f32 = 0;
        while (i < n) : (i += 1) {
            const u = i / (n - 1);
            const a = a0 + u * (a1 - a0);
            const lx = p1.x + @cos(a) * lw;
            const ly = p1.y + @sin(a) * lw;
            dst[dst_i].set(lx, ly, lu, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x, p1.y, 0.5, 1);
            dst_i += 1;
        }

        dst[dst_i].set(p1.x + dlx1 * rw, p1.y + dly1 * rw, lu, 1);
        dst_i += 1;
        dst[dst_i].set(rx1, ry1, ru, 1);
        dst_i += 1;
    }

    return dst_i;
}

fn bevelJoin(dst: []Vertex, p0: Point, p1: Point, lw: f32, rw: f32, lu: f32, ru: f32, fringe: f32) u32 {
    var rx0: f32 = undefined;
    var ry0: f32 = undefined;
    var rx1: f32 = undefined;
    var ry1: f32 = undefined;
    var lx0: f32 = undefined;
    var ly0: f32 = undefined;
    var lx1: f32 = undefined;
    var ly1: f32 = undefined;
    const dlx0 = p0.dy;
    const dly0 = -p0.dx;
    const dlx1 = p1.dy;
    const dly1 = -p1.dx;
    _ = fringe;
    var dst_i: u32 = 0;

    if ((p1.flags & @enumToInt(PointFlag.left)) != 0) {
        chooseBevel((p1.flags & @enumToInt(PointFlag.innerbevel)) != 0, p0, p1, lw, &lx0, &ly0, &lx1, &ly1);

        dst[dst_i].set(lx0, ly0, lu, 1);
        dst_i += 1;
        dst[dst_i].set(p1.x - dlx0 * rw, p1.y - dly0 * rw, ru, 1);
        dst_i += 1;

        if ((p1.flags & @enumToInt(PointFlag.bevel)) != 0) {
            dst[dst_i].set(lx0, ly0, lu, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x - dlx0 * rw, p1.y - dly0 * rw, ru, 1);
            dst_i += 1;

            dst[dst_i].set(lx1, ly1, lu, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x - dlx1 * rw, p1.y - dly1 * rw, ru, 1);
            dst_i += 1;
        } else {
            rx0 = p1.x - p1.dmx * rw;
            ry0 = p1.y - p1.dmy * rw;

            dst[dst_i].set(p1.x, p1.y, 0.5, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x - dlx0 * rw, p1.y - dly0 * rw, ru, 1);
            dst_i += 1;

            dst[dst_i].set(rx0, ry0, ru, 1);
            dst_i += 1;
            dst[dst_i].set(rx0, ry0, ru, 1);
            dst_i += 1;

            dst[dst_i].set(p1.x, p1.y, 0.5, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x - dlx1 * rw, p1.y - dly1 * rw, ru, 1);
            dst_i += 1;
        }

        dst[dst_i].set(lx1, ly1, lu, 1);
        dst_i += 1;
        dst[dst_i].set(p1.x - dlx1 * rw, p1.y - dly1 * rw, ru, 1);
        dst_i += 1;
    } else {
        chooseBevel((p1.flags & @enumToInt(PointFlag.innerbevel)) != 0, p0, p1, -rw, &rx0, &ry0, &rx1, &ry1);

        dst[dst_i].set(p1.x + dlx0 * lw, p1.y + dly0 * lw, lu, 1);
        dst_i += 1;
        dst[dst_i].set(rx0, ry0, ru, 1);
        dst_i += 1;

        if ((p1.flags & @enumToInt(PointFlag.bevel)) != 0) {
            dst[dst_i].set(p1.x + dlx0 * lw, p1.y + dly0 * lw, lu, 1);
            dst_i += 1;
            dst[dst_i].set(rx0, ry0, ru, 1);
            dst_i += 1;

            dst[dst_i].set(p1.x + dlx1 * lw, p1.y + dly1 * lw, lu, 1);
            dst_i += 1;
            dst[dst_i].set(rx1, ry1, ru, 1);
            dst_i += 1;
        } else {
            lx0 = p1.x + p1.dmx * lw;
            ly0 = p1.y + p1.dmy * lw;

            dst[dst_i].set(p1.x + dlx0 * lw, p1.y + dly0 * lw, lu, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x, p1.y, 0.5, 1);
            dst_i += 1;

            dst[dst_i].set(lx0, ly0, lu, 1);
            dst_i += 1;
            dst[dst_i].set(lx0, ly0, lu, 1);
            dst_i += 1;

            dst[dst_i].set(p1.x + dlx1 * lw, p1.y + dly1 * lw, lu, 1);
            dst_i += 1;
            dst[dst_i].set(p1.x, p1.y, 0.5, 1);
            dst_i += 1;
        }

        dst[dst_i].set(p1.x + dlx1 * lw, p1.y + dly1 * lw, lu, 1);
        dst_i += 1;
        dst[dst_i].set(rx1, ry1, ru, 1);
        dst_i += 1;
    }

    return dst_i;
}

fn buttCapStart(dst: []Vertex, p: Point, dx: f32, dy: f32, w: f32, d: f32, aa: f32, @"u0": f32, @"u1": f32) u32 {
    const px = p.x - dx * d;
    const py = p.y - dy * d;
    const dlx = dy;
    const dly = -dx;
    var dst_i: u32 = 0;
    dst[dst_i].set(px + dlx * w - dx * aa, py + dly * w - dy * aa, @"u0", 0);
    dst_i += 1;
    dst[dst_i].set(px - dlx * w - dx * aa, py - dly * w - dy * aa, @"u1", 0);
    dst_i += 1;
    dst[dst_i].set(px + dlx * w, py + dly * w, @"u0", 1);
    dst_i += 1;
    dst[dst_i].set(px - dlx * w, py - dly * w, @"u1", 1);
    dst_i += 1;
    return dst_i;
}

fn buttCapEnd(dst: []Vertex, p: Point, dx: f32, dy: f32, w: f32, d: f32, aa: f32, @"u0": f32, @"u1": f32) u32 {
    const px = p.x + dx * d;
    const py = p.y + dy * d;
    const dlx = dy;
    const dly = -dx;
    var dst_i: u32 = 0;
    dst[dst_i].set(px + dlx * w, py + dly * w, @"u0", 1);
    dst_i += 1;
    dst[dst_i].set(px - dlx * w, py - dly * w, @"u1", 1);
    dst_i += 1;
    dst[dst_i].set(px + dlx * w + dx * aa, py + dly * w + dy * aa, @"u0", 0);
    dst_i += 1;
    dst[dst_i].set(px - dlx * w + dx * aa, py - dly * w + dy * aa, @"u1", 0);
    dst_i += 1;
    return dst_i;
}

fn roundCapStart(dst: []Vertex, p: Point, dx: f32, dy: f32, w: f32, ncap: u32, aa: f32, @"u0": f32, @"u1": f32) u32 {
    const px = p.x;
    const py = p.y;
    const dlx = dy;
    const dly = -dx;
    _ = aa;
    var dst_i: u32 = 0;
    var i: u32 = 0;
    while (i < ncap) : (i += 1) {
        const a = @intToFloat(f32, i) / @intToFloat(f32, ncap - 1) * std.math.pi;
        const ax = @cos(a) * w;
        const ay = @sin(a) * w;
        dst[dst_i].set(px - dlx * ax - dx * ay, py - dly * ax - dy * ay, @"u0", 1);
        dst_i += 1;
        dst[dst_i].set(px, py, 0.5, 1);
        dst_i += 1;
    }
    dst[dst_i].set(px + dlx * w, py + dly * w, @"u0", 1);
    dst_i += 1;
    dst[dst_i].set(px - dlx * w, py - dly * w, @"u1", 1);
    dst_i += 1;
    return dst_i;
}

fn roundCapEnd(dst: []Vertex, p: Point, dx: f32, dy: f32, w: f32, ncap: u32, aa: f32, @"u0": f32, @"u1": f32) u32 {
    const px = p.x;
    const py = p.y;
    const dlx = dy;
    const dly = -dx;
    _ = aa;
    var dst_i: u32 = 0;
    dst[dst_i].set(px + dlx * w, py + dly * w, @"u0", 1);
    dst_i += 1;
    dst[dst_i].set(px - dlx * w, py - dly * w, @"u1", 1);
    dst_i += 1;
    var i: u32 = 0;
    while (i < ncap) : (i += 1) {
        const a = @intToFloat(f32, i) / @intToFloat(f32, ncap - 1) * std.math.pi;
        const ax = @cos(a) * w;
        const ay = @sin(a) * w;
        dst[dst_i].set(px, py, 0.5, 1);
        dst_i += 1;
        dst[dst_i].set(px - dlx * ax + dx * ay, py - dly * ax + dy * ay, @"u0", 1);
        dst_i += 1;
    }
    return dst_i;
}
