const std = @import("std");
const gk = @import("gamekit");
const assets = @import("assets.zig");
const game_data = @import("game_data.zig");
const settings = @import("settings.zig");
const requests = @import("requests.zig");
const network = @import("network.zig");
const builtin = @import("builtin");
const xml = @import("xml.zig");
const asset_dir = @import("build_options").asset_dir;
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zstbi = @import("zstbi");
const input = @import("input.zig");
const utils = @import("utils.zig");
const camera = @import("camera.zig");
const map = @import("map.zig");
const ui = @import("ui/ui.zig");
const render = @import("render.zig");
const ztracy = @import("ztracy");
const zaudio = @import("zaudio");
const screen_controller = @import("ui/controllers/screen_controller.zig");

pub const ServerData = struct {
    name: [:0]const u8 = "",
    dns: [:0]const u8 = "",
    port: u16,
    max_players: u16,
    admin_only: bool,

    pub fn parse(node: xml.Node, allocator: std.mem.Allocator) !ServerData {
        return ServerData{
            .name = try node.getValueAllocZ("Name", allocator, "Unknown"),
            .dns = try node.getValueAllocZ("DNS", allocator, "127.0.0.1"),
            .port = try node.getValueInt("Port", u16, 2050),
            .max_players = try node.getValueInt("MaxPlayers", u16, 0),
            .admin_only = node.elementExists("AdminOnly") and std.mem.eql(u8, node.getValue("AdminOnly").?, "true"),
        };
    }
};

pub const AccountData = struct {
    name: [:0]const u8 = "",
    email: []const u8 = "",
    password: []const u8 = "",
    admin: bool = false,
    guild_name: []const u8 = "",
    guild_rank: u8 = 0,
};

// todo nilly stats (def etc)
pub const CharacterData = struct {
    id: u32 = 0,
    tier: u8 = 1,
    obj_type: u16 = 0x00,
    name: []const u8 = "",
    health: u16 = 100,
    mana: u16 = 0,
    tex1: u32 = 0,
    tex2: u32 = 0,
    texture: u16 = 0,
    health_pots: i8 = 0,
    magic_pots: i8 = 0,
    has_backpack: bool = false,
    equipment: [20]u16 = std.mem.zeroes([20]u16),

    pub fn parse(allocator: std.mem.Allocator, node: xml.Node, id: u32) !CharacterData {
        const obj_type = try node.getValueInt("ObjectType", u16, 0);
        return CharacterData{
            .id = id,
            .obj_type = obj_type,
            .tex1 = try node.getValueInt("Tex1", u32, 0),
            .tex2 = try node.getValueInt("Tex2", u32, 0),
            .texture = try node.getValueInt("Texture", u16, 0),
            .health_pots = try node.getValueInt("HealthStackCount", i8, 0),
            .magic_pots = try node.getValueInt("MagicStackCount", i8, 0),
            .has_backpack = try node.getValueInt("HasBackpack", i8, 0) > 0,
            .name = try allocator.dupe(u8, game_data.obj_type_to_name.get(obj_type) orelse "Unknown Class"),
        };
    }
};

const embedded_font_data = @embedFile(asset_dir ++ "fonts/Ubuntu-Medium.ttf");

pub var gctx: *zgpu.GraphicsContext = undefined;
pub var network_fba: std.heap.FixedBufferAllocator = undefined;
pub var network_stack_allocator: std.mem.Allocator = undefined;
pub var current_account = AccountData{};
pub var character_list: []CharacterData = undefined;
pub var server_list: ?[]ServerData = null;
pub var selected_char_id: u32 = 65535;
pub var char_create_type: u16 = 0;
pub var char_create_skin_type: u16 = 0;
pub var selected_server: ?ServerData = null;
pub var next_char_id: u32 = 0;
pub var max_chars: u32 = 0;
pub var current_time: i64 = 0;
pub var network_thread: std.Thread = undefined;
pub var tick_network = true;
pub var render_thread: std.Thread = undefined;
pub var tick_render = true;
pub var tick_frame = false;
pub var sent_hello = false;
pub var editing_map = false;
pub var need_minimap_update = false;
pub var need_force_update = false;
pub var minimap_update_min_x: u32 = 4096;
pub var minimap_update_max_x: u32 = 0;
pub var minimap_update_min_y: u32 = 4096;
pub var minimap_update_max_y: u32 = 0;
pub var _allocator: std.mem.Allocator = undefined;

fn onResize(_: *zglfw.Window, w: i32, h: i32) callconv(.C) void {
    const float_w: f32 = @floatFromInt(w);
    const float_h: f32 = @floatFromInt(h);

    camera.screen_width = float_w;
    camera.screen_height = float_h;
    camera.clip_scale_x = 2.0 / float_w;
    camera.clip_scale_y = 2.0 / float_h;

    screen_controller.resize(float_w, float_h);
}

fn networkTick(allocator: *std.mem.Allocator) void {
    while (tick_network) {
        std.time.sleep(10 * std.time.ns_per_ms);

        if (selected_server) |sel_srv| {
            if (!network.connected)
                network.init(sel_srv.dns, sel_srv.port, allocator);

            if (network.connected) {
                if (selected_char_id != 65535 and !sent_hello) {
                    network.queuePacket(.{ .hello = .{
                        .build_ver = settings.build_version,
                        .game_id = -1,
                        .email = current_account.email,
                        .password = current_account.password,
                        .char_id = @intCast(selected_char_id),
                        .create_char = char_create_type != 0,
                        .class_type = char_create_type,
                        .skin_type = char_create_skin_type,
                    } });
                    sent_hello = true;
                }

                network.accept(allocator.*);
            }
        }
    }
}

fn renderTick(allocator: std.mem.Allocator) !void {
    var time_start = std.time.nanoTimestamp();
    while (tick_render) {
        if (!settings.enable_vsync and settings.fps_cap > 0) {
            // Sleep is unreliable, the fps cap would be slightly lower than the actual cap.
            // So we have to sleep 1.3x shorter and just loop for the rest of the time remaining
            const sleep_time: i64 = @intFromFloat(1000 * std.time.ns_per_ms / settings.fps_cap / 1.3);
            const time_offset = std.time.nanoTimestamp() - time_start;
            if (time_offset < sleep_time)
                std.time.sleep(@intCast(sleep_time - time_offset));

            const cap_time: i64 = @intFromFloat(1000 * std.time.ns_per_ms / settings.fps_cap);
            const time = std.time.nanoTimestamp();
            if (time - time_start < cap_time)
                continue;

            time_start = time;
        }

        const back_buffer = gctx.swapchain.getCurrentTextureView();
        const encoder = gctx.device.createCommandEncoder(null);

        render.draw(current_time, gctx, back_buffer, encoder);

        const commands = encoder.finish(null);
        gctx.submit(&.{commands});
        if (gctx.present() == .swap_chain_resized)
            render.createColorTexture(gctx, gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height);

        back_buffer.release();
        encoder.release();
        commands.release();

        // this has to be updated on render thread to avoid headaches (gctx sharing)
        if (screen_controller.current_screen == .game and screen_controller.current_screen.game.inited and settings.stats_enabled)
            try screen_controller.current_screen.game.updateFpsText(gctx.stats.fps, try utils.currentMemoryUse());

        // this has to be updated on render thread to avoid headaches (gctx sharing)
        if (screen_controller.current_screen == .editor and settings.stats_enabled)
            try screen_controller.current_screen.editor.updateFpsText(gctx.stats.fps, try utils.currentMemoryUse());

        minimapUpdate: {
            if (need_minimap_update) {
                // we need to make copies of these, other threads can change them mid execution
                // this is a hack though. should be handled double buffered or else chunks of minimap can be lost
                const min_x = minimap_update_min_x;
                const max_x = minimap_update_max_x + 1;
                const min_y = minimap_update_min_y;
                const max_y = minimap_update_max_y + 1;

                const w = max_x - min_x;
                const h = max_y - min_y;
                if (w <= 0 or h <= 0)
                    break :minimapUpdate;

                const comp_len = map.minimap.num_components * map.minimap.bytes_per_component;
                const copy = allocator.alloc(u8, w * h * comp_len) catch |e| {
                    std.log.err("Minimap alloc failed: {any}", .{e});
                    need_minimap_update = false;
                    minimap_update_min_x = 4096;
                    minimap_update_max_x = 0;
                    minimap_update_min_y = 4096;
                    minimap_update_max_y = 0;
                    break :minimapUpdate;
                };
                defer allocator.free(copy);

                var idx: u32 = 0;
                for (min_y..max_y) |y| {
                    const base_map_idx = y * map.minimap.width * comp_len + min_x * comp_len;
                    @memcpy(
                        copy[idx * w * comp_len .. (idx + 1) * w * comp_len],
                        map.minimap.data[base_map_idx .. base_map_idx + w * comp_len],
                    );
                    idx += 1;
                }

                gctx.queue.writeTexture(
                    .{
                        .texture = gctx.lookupResource(render.minimap_texture).?,
                        .origin = .{
                            .x = min_x,
                            .y = min_y,
                        },
                    },
                    .{
                        .bytes_per_row = comp_len * w,
                        .rows_per_image = h,
                    },
                    .{
                        .width = w,
                        .height = h,
                    },
                    u8,
                    copy,
                );

                need_minimap_update = false;
                minimap_update_min_x = 4096;
                minimap_update_max_x = 0;
                minimap_update_min_y = 4096;
                minimap_update_max_y = 0;
            } else if (need_force_update) {
                gctx.queue.writeTexture(
                    .{
                        .texture = gctx.lookupResource(render.minimap_texture).?,
                    },
                    .{
                        .bytes_per_row = map.minimap.bytes_per_row,
                        .rows_per_image = map.minimap.height,
                    },
                    .{
                        .width = map.minimap.width,
                        .height = map.minimap.height,
                    },
                    u8,
                    map.minimap.data,
                );
                need_force_update = false;
            }
        }
    }
}

pub fn clear() void {
    map.dispose(_allocator);
    need_force_update = true;
}

pub fn disconnect() void {
    if (network.connected) {
        network.deinit(&_allocator);
        selected_server = null;
        sent_hello = false;
    }
    clear();
    input.reset();
    screen_controller.switchScreen(.char_select);
}

// This is effectively just raw_c_allocator wrapped in the Tracy stuff
fn tracyAlloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    const malloc = std.c.malloc(len);
    ztracy.Alloc(malloc, len);
    return @as(?[*]u8, @ptrCast(malloc));
}

fn tracyResize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    return new_len <= buf.len;
}

fn tracyFree(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    ztracy.Free(buf.ptr);
    std.c.free(buf.ptr);
}

pub fn main() !void {
    // needed for tracy to register
    var main_zone: ztracy.ZoneCtx = undefined;
    if (settings.enable_tracy)
        main_zone = ztracy.ZoneNC(@src(), "Main Zone", 0x00FF0000);
    defer if (settings.enable_tracy) main_zone.End();

    const start_time = std.time.microTimestamp();
    utils.rng.seed(@as(u64, @intCast(start_time)));

    const is_debug = builtin.mode == .Debug;
    var gpa = if (is_debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer _ = if (is_debug) gpa.deinit();

    const tracy_allocator_vtable = std.mem.Allocator.VTable{
        .alloc = tracyAlloc,
        .resize = tracyResize,
        .free = tracyFree,
    };
    const tracy_allocator = std.mem.Allocator{
        .ptr = undefined,
        .vtable = &tracy_allocator_vtable,
    };

    var allocator = if (settings.enable_tracy) tracy_allocator else switch (builtin.mode) {
        .Debug => gpa.allocator(),
        .ReleaseSafe => std.heap.c_allocator,
        .ReleaseFast, .ReleaseSmall => std.heap.raw_c_allocator,
    };
    _allocator = allocator;

    var network_buf: [std.math.maxInt(u16)]u8 = undefined;
    network_fba = std.heap.FixedBufferAllocator.init(&network_buf);
    network_stack_allocator = network_fba.allocator();

    zglfw.init() catch |e| {
        std.log.err("Failed to initialize GLFW library: {any}", .{e});
        return;
    };
    defer zglfw.terminate();

    zstbi.init(allocator);
    defer zstbi.deinit();

    zaudio.init(allocator);
    defer zaudio.deinit();

    try settings.init(allocator);
    defer settings.deinit();

    try assets.init(allocator);
    defer assets.deinit(allocator);

    try game_data.init(allocator);
    defer game_data.deinit(allocator);

    requests.init(allocator);
    defer requests.deinit();

    try map.init(allocator);
    defer map.deinit(allocator);

    input.init(allocator);
    defer input.deinit(allocator);

    try screen_controller.init(allocator);
    defer screen_controller.deinit();

    screen_controller.switchScreen(.main_menu);

    zglfw.WindowHint.set(.client_api, @intFromEnum(zglfw.ClientApi.no_api));
    const window = zglfw.Window.create(1280, 720, "Client", null) catch |e| {
        std.log.err("Failed to create window: {any}", .{e});
        return;
    };
    defer window.destroy();
    window.setSizeLimits(1280, 720, -1, -1);
    window.setCursor(switch (settings.selected_cursor) {
        .basic => assets.default_cursor,
        .royal => assets.royal_cursor,
        .ranger => assets.ranger_cursor,
        .aztec => assets.aztec_cursor,
        .fiery => assets.fiery_cursor,
        .target_enemy => assets.target_enemy_cursor,
        .target_ally => assets.target_ally_cursor,
    });

    gctx = zgpu.GraphicsContext.create(
        allocator,
        window,
        .{ .present_mode = if (settings.enable_vsync) .fifo else .immediate },
    ) catch |e| {
        std.log.err("Failed to create graphics context: {any}", .{e});
        return;
    };
    defer gctx.destroy(allocator);

    _ = window.setKeyCallback(input.keyEvent);
    _ = window.setCharCallback(input.charEvent);
    _ = window.setCursorPosCallback(input.mouseMoveEvent);
    _ = window.setMouseButtonCallback(input.mouseEvent);
    _ = window.setScrollCallback(input.scrollEvent);
    _ = window.setFramebufferSizeCallback(onResize);

    render.init(gctx, allocator);
    defer render.deinit(allocator);

    network_thread = try std.Thread.spawn(.{}, networkTick, .{&allocator});
    defer {
        tick_network = false;
        network_thread.join();
    }

    render_thread = try std.Thread.spawn(.{}, renderTick, .{allocator});
    defer {
        tick_render = false;
        render_thread.join();
    }

    var last_update: i64 = 0;
    while (!window.shouldClose()) {
        const time = std.time.microTimestamp() - start_time;
        current_time = time;

        zglfw.pollEvents();

        if (tick_frame or editing_map) {
            const dt = time - last_update;
            map.update(time, dt, allocator);
            try screen_controller.update(time, dt, allocator);
        }

        last_update = time;

        std.time.sleep(6.5 * std.time.ns_per_ms);
    }

    defer {
        if (current_account.name.len > 0)
            allocator.free(current_account.name);

        if (current_account.email.len > 0)
            allocator.free(current_account.email);

        if (current_account.password.len > 0)
            allocator.free(current_account.password);

        if (network.connected)
            network.deinit(&allocator);

        if (character_list.len > 0) {
            for (character_list) |char| {
                allocator.free(char.name);
            }
            allocator.free(character_list);
        }

        if (server_list) |srv_list| {
            for (srv_list) |srv| {
                allocator.free(srv.name);
                allocator.free(srv.dns);
            }
            allocator.free(srv_list);
        }
    }
}
