package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:mem"
import "core:os"
import t "core:time"

import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import slog "sokol/log"

import shade "shader"
import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

app_state: struct {
	pass_action:   sg.Pass_Action,
	pip:           sg.Pipeline,
	bind:          sg.Bindings,
  game_state: Game_State,
	input_state:   Input_State,
}

UserID :: u64

WINDOW_W :: 1280
WINDOW_H :: 720

main :: proc() {
	sapp.run(
		{
			init_cb = init_callback, // load
			frame_cb = frame_callback, // update and render
			cleanup_cb = cleanup_callback, // end
			event_cb = event_callback, // event handler
			width = WINDOW_W,
			height = WINDOW_H,
			window_title = "This hot sauce is mine now eheheheheh!!",
			icon = {sokol_default = true},
			logger = {func = slog.func},
		},
	)
}

init_callback :: proc "c" () {
	using linalg, fmt
	context = runtime.default_context()

	init_time = t.now()

	sg.setup(
		{
			environment = sglue.environment(),
			logger = {func = slog.func},
			d3d11_shader_debugging = ODIN_DEBUG,
		},
	)

	init_images()
	init_fonts()

  gs = &app_state.game_state

	// make the vertex buffer
	app_state.bind.vertex_buffers[0] = sg.make_buffer(
		{usage = .DYNAMIC, size = size_of(Quad) * len(draw_frame.quads)},
	)

	// make & fill the index buffer
	index_buffer_count :: MAX_QUADS * 6
	indices: [index_buffer_count]u16
	i := 0
	for i < index_buffer_count {
		// vertex offset pattern to draw a quad
		// { 0, 1, 2,  0, 2, 3 }
		indices[i + 0] = auto_cast ((i / 6) * 4 + 0)
		indices[i + 1] = auto_cast ((i / 6) * 4 + 1)
		indices[i + 2] = auto_cast ((i / 6) * 4 + 2)
		indices[i + 3] = auto_cast ((i / 6) * 4 + 0)
		indices[i + 4] = auto_cast ((i / 6) * 4 + 2)
		indices[i + 5] = auto_cast ((i / 6) * 4 + 3)
		i += 6
	}
	app_state.bind.index_buffer = sg.make_buffer(
		{type = .INDEXBUFFER, data = {ptr = &indices, size = size_of(indices)}},
	)

	// image stuff
	app_state.bind.samplers[shade.SMP_default_sampler] = sg.make_sampler({})

	// setup pipeline
	pipeline_desc: sg.Pipeline_Desc = {
		shader = sg.make_shader(shade.quad_shader_desc(sg.query_backend())),
		index_type = .UINT16,
		layout = {
			attrs = {
				shade.ATTR_quad_position = {format = .FLOAT2},
				shade.ATTR_quad_color0 = {format = .FLOAT4},
				shade.ATTR_quad_uv0 = {format = .FLOAT2},
				shade.ATTR_quad_bytes0 = {format = .UBYTE4N},
				shade.ATTR_quad_color_override0 = {format = .FLOAT4},
			},
		},
	}
	blend_state: sg.Blend_State = {
		enabled          = true,
		src_factor_rgb   = .SRC_ALPHA,
		dst_factor_rgb   = .ONE_MINUS_SRC_ALPHA,
		op_rgb           = .ADD,
		src_factor_alpha = .ONE,
		dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
		op_alpha         = .ADD,
	}
	pipeline_desc.colors[0] = {
		blend = blend_state,
	}
	app_state.pip = sg.make_pipeline(pipeline_desc)

	// default pass action
	app_state.pass_action = {
		colors = {0 = {load_action = .CLEAR, clear_value = {0, 0, 0, 1}}},
	}
}

//
// :FRAME

// global since need to keep these alive till the app ends.
last_time: t.Time
accumulator: f64

// todo: Cap to display device frame rate)
// If not capped to max device frame rate,
// sad shit happens
seconds_per_sim :: 1.0 / 60.0
last_sim_time: f64 = 0.0

frame_callback :: proc "c" () {
	using runtime, linalg
	context = runtime.default_context()

  draw_frame = {}// mem.set(&draw_frame, 0, size_of(draw_frame))
  update_and_render()

	app_state.bind.images[shade.IMG_tex0] = atlas.sg_image
	app_state.bind.images[shade.IMG_tex1] = images[font.img_id].sg_img

	sg.update_buffer(
		app_state.bind.vertex_buffers[0],
		{ptr = &draw_frame.quads[0], size = size_of(Quad) * len(draw_frame.quads)},
	)
	sg.begin_pass({action = app_state.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(app_state.pip)
	sg.apply_bindings(app_state.bind)
	sg.draw(0, 6 * draw_frame.quad_count, 1)
	sg.end_pass()
	sg.commit()

	reset_input(&app_state.input_state)
}

cleanup_callback :: proc "c" () {
	context = runtime.default_context()
	sg.shutdown()
}

//
// :UTILS

DEFAULT_UV :: v4{0, 0, 1, 1}
Vector2i :: [2]int
Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
v2 :: Vector2
v3 :: Vector3
v4 :: Vector4
Matrix4 :: linalg.Matrix4f32

COLOR_WHITE :: Vector4{1, 1, 1, 1}
COLOR_RED :: Vector4{1, 0, 0, 1}

// might do something with these later on
loggie :: fmt.println // log is already used........
log_error :: fmt.println
log_warning :: fmt.println

init_time: t.Time
seconds_since_init :: proc() -> f64 {
	using t
	if init_time._nsec == 0 {
		log_error("invalid time")
		return 0
	}
	return duration_seconds(since(init_time))
}

xform_translate :: proc(pos: Vector2) -> Matrix4 {
	return linalg.matrix4_translate(v3{pos.x, pos.y, 0})
}
xform_rotate :: proc(angle: f32) -> Matrix4 {
	return linalg.matrix4_rotate(math.to_radians(angle), v3{0, 0, 1})
}
xform_scale :: proc(scale: Vector2) -> Matrix4 {
	return linalg.matrix4_scale(v3{scale.x, scale.y, 1})
}

Pivot :: enum {
	bottom_left,
	bottom_center,
	bottom_right,
	center_left,
	center_center,
	center_right,
	top_left,
	top_center,
	top_right,
}
scale_from_pivot :: proc(pivot: Pivot) -> Vector2 {
	switch pivot {
	case .bottom_left:
		return v2{0.0, 0.0}
	case .bottom_center:
		return v2{0.5, 0.0}
	case .bottom_right:
		return v2{1.0, 0.0}
	case .center_left:
		return v2{0.0, 0.5}
	case .center_center:
		return v2{0.5, 0.5}
	case .center_right:
		return v2{1.0, 0.5}
	case .top_center:
		return v2{0.5, 1.0}
	case .top_left:
		return v2{0.0, 1.0}
	case .top_right:
		return v2{1.0, 1.0}
	}
	return {}
}

sine_breathe :: proc(p: $T) -> T where intrinsics.type_is_float(T) {
	return (math.sin((p - .25) * 2.0 * math.PI) / 2.0) + 0.5
}

// :INPUT
//

// number of keycodes we want in the game 
// keyboard keys + mouse buttons (with some extra buffer)
// This is not the exact number as this is used to set the size of 
// Input_State.keys
MAX_KEYCODES :: 512
MAX_MOUSE_BUTTONS :: 5
MAX_MODIFIERS :: 10

Key_State :: enum {
	down,
	pressed,
	released,
	repeat,
}

Mouse_Code :: enum {
	MOUSE_LEFT    = 0,
	MOUSE_RIGHT   = 1,
	MOUSE_MIDDLE  = 2,
	MOUSE_INVALID = 3,
}

Input_State :: struct {
	keys:          [MAX_KEYCODES]bit_set[Key_State],
	mouse_buttons: [MAX_MOUSE_BUTTONS]bit_set[Key_State],
}

reset_input :: proc(input_state: ^Input_State) {
	for &key in input_state.keys {
		key -= {.pressed, .released, .repeat}
	}
	for &key in input_state.mouse_buttons {
		key -= {.pressed, .released, .repeat}
	}
}

map_mouse_keys :: proc "c" (button: sapp.Mousebutton) -> Mouse_Code {
	#partial switch button {
	case .LEFT:
		return .MOUSE_LEFT
	case .RIGHT:
		return .MOUSE_RIGHT
	case .MIDDLE:
		return .MOUSE_MIDDLE
	case .INVALID:
		return .MOUSE_INVALID
	}
	return nil
}

event_callback :: proc "c" (event: ^sapp.Event) {
	input_state := &app_state.input_state
	#partial switch event.type {
	case .KEY_DOWN:
		input_state.keys[event.key_code] += {.down, .pressed}
	case .KEY_UP:
		input_state.keys[event.key_code] -= {.down}
		input_state.keys[event.key_code] += {.released}
	case .MOUSE_UP:
		key := map_mouse_keys(event.mouse_button)
		input_state.mouse_buttons[key] -= {.down}
		input_state.mouse_buttons[key] += {.released}
	case .MOUSE_DOWN:
		input_state.mouse_buttons[event.key_code] += {.down, .pressed}
	}
}

key_event :: proc(input_state: Input_State, keycode: sapp.Keycode, key_state: Key_State) -> bool {
	return key_state in input_state.keys[keycode]
}

mouse_event :: proc(input_state: Input_State, keycode: Mouse_Code, key_state: Key_State) -> bool {
	return key_state in input_state.mouse_buttons[keycode]
}

//
// :RENDER
//
// API ordered highest -> lowest level

draw_sprite :: proc(
	pos: Vector2,
	img_id: Image_Id,
	pivot := Pivot.bottom_left,
	xform := Matrix4(1),
	color_override := v4{0, 0, 0, 0},
) {
	image := images[img_id]
	size := v2{auto_cast image.width, auto_cast image.height}

	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform // we slide in here because rotations + scales work nicely at this point
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))

	draw_rect_xform(
		xform0,
		size,
		img_id = img_id,
		color_override = color_override,
	)
}

draw_rect_aabb :: proc(
	pos: Vector2,
	size: Vector2,
	col: Vector4 = COLOR_WHITE,
	uv: Vector4 = DEFAULT_UV,
	img_id: Image_Id = .nil,
	color_override := v4{0, 0, 0, 0},
) {
	xform := linalg.matrix4_translate(v3{pos.x, pos.y, 0})
	draw_rect_xform(xform, size, col, uv, img_id, color_override)
}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4 = COLOR_WHITE,
	uv: Vector4 = DEFAULT_UV,
	img_id: Image_Id = .nil,
	color_override := v4{0, 0, 0, 0},
) {
	draw_rect_projected(
		draw_frame.projection * draw_frame.camera_xform * xform,
		size,
		col,
		uv,
		img_id,
		color_override,
	)
}

Vertex :: struct {
	pos:            Vector2,
	col:            Vector4,
	uv:             Vector2,
	tex_index:      u8,
	_pad:           [3]u8,
	color_override: Vector4,
}

Quad :: [4]Vertex

MAX_QUADS :: 8192
MAX_VERTS :: MAX_QUADS * 4

Draw_Frame :: struct {
	quads:                  [MAX_QUADS]Quad,
	scuffed_deferred_quads: [MAX_QUADS / 4]Quad,
	projection:             Matrix4,
	camera_xform:           Matrix4,
	using reset:            struct {
		quad_count:                  int,
		scuffed_deferred_quad_count: int,
	},
}
draw_frame: Draw_Frame

// below is the lower level draw rect stuff

draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4 = COLOR_WHITE,
	uv: Vector4 = DEFAULT_UV,
	img_id: Image_Id = .nil,
	color_override := v4{0, 0, 0, 0},
) {

	bl := v2{0, 0}
	tl := v2{0, size.y}
	tr := v2{size.x, size.y}
	br := v2{size.x, 0}

	uv0 := uv
	if uv == DEFAULT_UV {
		uv0 = images[img_id].atlas_uvs
	}

	tex_index: u8 = images[img_id].tex_index
	if img_id == .nil {
		tex_index = 255 // bypasses texture sampling
	}

	draw_quad_projected(
		world_to_clip,
		{bl, tl, tr, br},
		{col, col, col, col},
		{uv0.xy, uv0.xw, uv0.zw, uv0.zy},
		{tex_index, tex_index, tex_index, tex_index},
		{color_override, color_override, color_override, color_override},
	)

}

draw_quad_projected :: proc(
	world_to_clip: Matrix4,
	positions: [4]Vector2,
	colors: [4]Vector4,
	uvs: [4]Vector2,
	tex_indicies: [4]u8,
	//flags:           [4]Quad_Flags,
	color_overrides: [4]Vector4,
	//hsv:             [4]Vector3
) {
	using linalg

	if draw_frame.quad_count >= MAX_QUADS {
		log_error("max quads reached")
		return
	}

	verts := cast(^[4]Vertex)&draw_frame.quads[draw_frame.quad_count]
  draw_frame.quad_count += 1

	verts[0].pos = (world_to_clip * Vector4{positions[0].x, positions[0].y, 0.0, 1.0}).xy
	verts[1].pos = (world_to_clip * Vector4{positions[1].x, positions[1].y, 0.0, 1.0}).xy
	verts[2].pos = (world_to_clip * Vector4{positions[2].x, positions[2].y, 0.0, 1.0}).xy
	verts[3].pos = (world_to_clip * Vector4{positions[3].x, positions[3].y, 0.0, 1.0}).xy

	verts[0].col = colors[0]
	verts[1].col = colors[1]
	verts[2].col = colors[2]
	verts[3].col = colors[3]

	verts[0].uv = uvs[0]
	verts[1].uv = uvs[1]
	verts[2].uv = uvs[2]
	verts[3].uv = uvs[3]

	verts[0].tex_index = tex_indicies[0]
	verts[1].tex_index = tex_indicies[1]
	verts[2].tex_index = tex_indicies[2]
	verts[3].tex_index = tex_indicies[3]

	verts[0].color_override = color_overrides[0]
	verts[1].color_override = color_overrides[1]
	verts[2].color_override = color_overrides[2]
	verts[3].color_override = color_overrides[3]
}

//
// :IMAGE
//
Image_Id :: enum {
	nil,
	player,
  dirt_tile,
  background_0
}

Image :: struct {
	width, height: i32,
	tex_index:     u8,
	sg_img:        sg.Image,
	data:          [^]byte,
	atlas_uvs:     Vector4,
}
images: [128]Image
image_count: int

init_images :: proc() {
	using fmt

	img_dir := "res/images/"

	highest_id := 0
	for img_name, id in Image_Id {
		if id == 0 {continue}

		if id > highest_id {
			highest_id = id
		}

		path := tprint(img_dir, img_name, ".png", sep = "")
		png_data, succ := os.read_entire_file(path)
		assert(succ)

		stbi.set_flip_vertically_on_load(1)
		width, height, channels: i32
		img_data := stbi.load_from_memory(
			raw_data(png_data),
			auto_cast len(png_data),
			&width,
			&height,
			&channels,
			4,
		)
		assert(img_data != nil, "stbi load failed, invalid image?")

		img: Image
		img.width = width
		img.height = height
		img.data = img_data

		images[id] = img
	}
	image_count = highest_id + 1

	pack_images_into_atlas()
}


// :ATLAS
//
Atlas :: struct {
	w, h:     int,
	sg_image: sg.Image,
}
atlas: Atlas
// We're hardcoded to use just 1 atlas now since I don't think we'll need more
// It would be easy enough to extend though. Just add in more texture slots in the shader
// :pack
pack_images_into_atlas :: proc() {

	// TODO - add a single pixel of padding for each so we avoid the edge oversampling issue

	// 8192 x 8192 is the WGPU recommended max I think
	atlas.w = 512
	atlas.h = 512

	cont: stbrp.Context
	nodes: [128]stbrp.Node // #volatile with atlas.w
	stbrp.init_target(&cont, auto_cast atlas.w, auto_cast atlas.h, &nodes[0], auto_cast atlas.w)

	rects: [dynamic]stbrp.Rect
	for img, id in images {
		if img.width == 0 {
			continue
		}
		append(
			&rects,
			stbrp.Rect{id = auto_cast id, w = auto_cast img.width, h = auto_cast img.height},
		)
	}

	succ := stbrp.pack_rects(&cont, &rects[0], auto_cast len(rects))
	if succ == 0 {
		assert(false, "failed to pack all the rects, ran out of space?")
	}

	// allocate big atlas
	raw_data, err := mem.alloc(atlas.w * atlas.h * 4)
	defer mem.free(raw_data)
	mem.set(raw_data, 255, atlas.w * atlas.h * 4)

	// copy rect row-by-row into destination atlas
	for rect in rects {
		img := &images[rect.id]

		// copy row by row into atlas
		for row in 0 ..< rect.h {
			src_row := mem.ptr_offset(&img.data[0], row * rect.w * 4)
			dest_row := mem.ptr_offset(
				cast(^u8)raw_data,
				((rect.y + row) * auto_cast atlas.w + rect.x) * 4,
			)
			mem.copy(dest_row, src_row, auto_cast rect.w * 4)
		}

		// yeet old data
		stbi.image_free(img.data)
		img.data = nil

		// img.atlas_x = auto_cast rect.x
		// img.atlas_y = auto_cast rect.y

		img.atlas_uvs.x = cast(f32)rect.x / cast(f32)atlas.w
		img.atlas_uvs.y = cast(f32)rect.y / cast(f32)atlas.h
		img.atlas_uvs.z = img.atlas_uvs.x + cast(f32)img.width / cast(f32)atlas.w
		img.atlas_uvs.w = img.atlas_uvs.y + cast(f32)img.height / cast(f32)atlas.h
	}

	stbi.write_png(
		"atlas.png",
		auto_cast atlas.w,
		auto_cast atlas.h,
		4,
		raw_data,
		4 * auto_cast atlas.w,
	)

	// setup image for GPU
	desc: sg.Image_Desc
	desc.width = auto_cast atlas.w
	desc.height = auto_cast atlas.h
	desc.pixel_format = .RGBA8
	desc.data.subimage[0][0] = {
		ptr  = raw_data,
		size = auto_cast (atlas.w * atlas.h * 4),
	}
	atlas.sg_image = sg.make_image(desc)
	if atlas.sg_image.id == sg.INVALID_ID {
		log_error("failed to make image")
	}
}

//
// :FONT
//
draw_text :: proc(pos: Vector2, text: string, scale := 1.0) {
	using stbtt

	x: f32
	y: f32

	for char in text {

		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(
			&font.char_data[0],
			font_bitmap_w,
			font_bitmap_h,
			cast(i32)char - 32,
			&advance_x,
			&advance_y,
			&q,
			false,
		)
		// this is the the data for the aligned_quad we're given, with y+ going down
		// x0, y0,     s0, t0, // top-left
		// x1, y1,     s1, t1, // bottom-right


		size := v2{abs(q.x0 - q.x1), abs(q.y0 - q.y1)}

		bottom_left := v2{q.x0, -q.y1}
		top_right := v2{q.x1, -q.y0}
		assert(bottom_left + size == top_right)

		offset_to_render_at := v2{x, y} + bottom_left

		uv := v4{q.s0, q.t1, q.s1, q.t0}

		xform := Matrix4(1)
		xform *= xform_translate(pos)
		xform *= xform_scale(v2{auto_cast scale, auto_cast scale})
		xform *= xform_translate(offset_to_render_at)
		draw_rect_xform(xform, size, uv = uv, img_id = font.img_id)

		x += advance_x
		y += -advance_y
	}

}

//
// :FONT
//
font_bitmap_w :: 256
font_bitmap_h :: 256
char_count :: 96
Font :: struct {
	char_data: [char_count]stbtt.bakedchar,
	img_id:    Image_Id,
}
font: Font

init_fonts :: proc() {
	using stbtt

	bitmap, _ := mem.alloc(font_bitmap_w * font_bitmap_h)
	font_height := 15 // for some reason this only bakes properly at 15 ? it's a 16px font dou...
	path := "res/fonts/alagard.ttf"
	ttf_data, err := os.read_entire_file(path)
	assert(ttf_data != nil, "failed to read font")

	ret := BakeFontBitmap(
		raw_data(ttf_data),
		0,
		auto_cast font_height,
		auto_cast bitmap,
		font_bitmap_w,
		font_bitmap_h,
		32,
		char_count,
		&font.char_data[0],
	)
	assert(ret > 0, "not enough space in bitmap")

	stbi.write_png(
		"font.png",
		auto_cast font_bitmap_w,
		auto_cast font_bitmap_h,
		1,
		bitmap,
		auto_cast font_bitmap_w,
	)

	// setup font atlas so we can use it in the shader
	desc: sg.Image_Desc
	desc.width = auto_cast font_bitmap_w
	desc.height = auto_cast font_bitmap_h
	desc.pixel_format = .R8
	desc.data.subimage[0][0] = {
		ptr  = bitmap,
		size = auto_cast (font_bitmap_w * font_bitmap_h),
	}
	sg_img := sg.make_image(desc)
	if sg_img.id == sg.INVALID_ID {
		log_error("failed to make image")
	}

	id := store_image(font_bitmap_w, font_bitmap_h, 1, sg_img)
	font.img_id = id
}
// kind scuffed...
// but I'm abusing the Images to store the font atlas by just inserting it at the end with the next id
store_image :: proc(w: int, h: int, tex_index: u8, sg_img: sg.Image) -> Image_Id {

	img: Image
	img.width = auto_cast w
	img.height = auto_cast h
	img.tex_index = tex_index
	img.sg_img = sg_img
	img.atlas_uvs = DEFAULT_UV

	id := image_count
	images[id] = img
	image_count += 1

	return auto_cast id
}

//
// :entity
//


Entity_ID :: u64

Entity_Handle :: struct {
  id: Entity_ID,
  index: int,
}

Entity_Type :: enum {
	nil,
	player,
}

Entity_Flags :: enum {
	allocated,
	physics,
}

Entity :: struct {
	handle:      Entity_Handle,
	type:    Entity_Type,
	pos:     Vector2,
	vel:     Vector2,
	acc:     Vector2,
	user_id: UserID,
	flags:   bit_set[Entity_Flags],
	frame:   struct {
		input_axis: Vector2,
	},
}

// Returns the Entity with Entity_ID == id
handle_to_entity:: proc(handle: Entity_Handle) -> ^Entity {
  en := &gs.entities[handle.index]
  if en.handle.id == handle.id {
    return en
  }
	log_error("entity does not exist")
	return nil
}

id_to_entity:: proc(id: Entity_ID) -> ^Entity {
  for &en in gs.entities {
    if en.handle.id == id {
      return &en
    }
  }
  return nil
}

// Returns the Entity_ID
entity_to_id :: proc(entity: Entity) -> Entity_ID{
	return entity.handle.id
}

entity_to_handle :: proc(entity: Entity) -> Entity_Handle{
	return entity.handle
}

entity_create :: proc() -> ^Entity {
	spare_en: ^Entity
  index := -1
	for &en, i in gs.entities {
		if !(.allocated in en.flags) {
			spare_en = &en
      index = i
			break
		}
	}
	if spare_en == nil {
		log_error("ran out of titties")
		return nil
	} else {
		spare_en.flags = {.allocated}
		gs.latest_entity_id += 1
		spare_en.handle.id = gs.latest_entity_id
		spare_en.handle.index = index
		return spare_en
	}
}

entity_destroy :: proc(entity: ^Entity) {
	mem.set(entity, 0, size_of(entity))
}

setup_player :: proc(e: ^Entity) {
	e.type = .player
	e.flags |= {.physics}
}

//
// :tiles
//

MAP_W_TILE :: 25
MAP_H_TILE :: 14
TILE_SIZE :: 16 // 16x16

Tile_Coords :: Vector2i
World_Pos :: Vector2
Local_Pos :: Vector2

Tile_Type :: enum {
  empty,
  dirt,
  tilled,
}

Tile :: struct {
  type: Tile_Type
}

local_coords_to_world_coords :: proc(pos: Tile_Coords) -> Tile_Coords{
  x_index := pos.x - int(math.floor(f32(MAP_W_TILE * 0.5)))
  y_index := pos.y - int(math.floor(f32(MAP_H_TILE * 0.5)))
  return Tile_Coords{x_index, y_index}
}

world_coords_to_local_coords :: proc(pos: Tile_Coords) -> Tile_Coords{
  x_index := pos.x + int(math.floor(f32(MAP_W_TILE * 0.5)))
  y_index := pos.y + int(math.floor(f32(MAP_H_TILE * 0.5)))
  return Tile_Coords{x_index, y_index}
}

tile_pos_to_world_pos :: proc(tile_pos: Tile_Coords) -> World_Pos {
  return World_Pos{
    f32(tile_pos.x * TILE_SIZE) - TILE_SIZE * MAP_W_TILE * 0.5, 
    f32(tile_pos.y * TILE_SIZE) - TILE_SIZE * MAP_H_TILE * 0.5
  }
}

world_pos_to_tile_pos :: proc(world_pos: World_Pos) -> Tile_Coords {
  return Tile_Coords{int(math.floor(world_pos.x/TILE_SIZE)), int(math.floor(world_pos.y/TILE_SIZE))}
}

//
// :game state
// 

Game_State :: struct {
  ticks: u64,
  entities: [128]Entity,
  latest_entity_id: Entity_ID,
  player_id: Entity_ID,
  
  tiles: [MAP_W_TILE * MAP_H_TILE]Tile
}
gs : ^Game_State

GAME_RES_W :: 480
GAME_RES_H :: 270

// Returns the player entity
get_player :: proc() -> ^Entity {
  return id_to_entity(gs.player_id)
}

get_delta_time :: proc() -> f64 {
  return sapp.frame_duration()
}

//
// :update and render
//
update_and_render :: proc() {
  defer gs.ticks += 1
  using linalg

  dt := get_delta_time()

  if key_event(app_state.input_state, .F11, .pressed) {
    sapp.toggle_fullscreen()
  }

  // :world setup
  if gs.ticks == 0 {
    en := entity_create()
    setup_player(en)
    gs.player_id = entity_to_id(en^)
  }

  for x in 0..<MAP_W_TILE {
    for y in 0..<MAP_H_TILE {
      if x %2 == y %2 {
        gs.tiles[y*MAP_W_TILE + x].type = .dirt
      }
    }
  }

  player := get_player()
  for &en in gs.entities {
    en.frame = {}
  }

  if key_event(app_state.input_state, .A, .down) {
    player.frame.input_axis.x += -1
  }
  if key_event(app_state.input_state, .D, .down) {
    player.frame.input_axis.x += 1
  }
  if key_event(app_state.input_state, .W, .down) {
    player.frame.input_axis.y += 1
  }
  if key_event(app_state.input_state, .S, .down) {
    player.frame.input_axis.y += -1
  }
  if length(player.frame.input_axis) != 0 {
  player.frame.input_axis = normalize(player.frame.input_axis)
  }
  player.pos += player.frame.input_axis * (100.0) * f32(dt)


  // :render
	draw_frame.projection = matrix_ortho3d_f32(WINDOW_W * -0.5, WINDOW_W * 0.5, WINDOW_H * -0.5, WINDOW_H * 0.5, -1, 1)
	
	draw_frame.camera_xform = Matrix4(1)
	draw_frame.camera_xform *= xform_scale(f32(WINDOW_W) / f32(GAME_RES_W))

  draw_rect_aabb(Vector2{GAME_RES_W * -0.5, GAME_RES_H * -0.5}, Vector2{GAME_RES_W, GAME_RES_H}, img_id=.background_0)


  // render tiles
  for x in 0..<MAP_W_TILE {
    for y in 0..<MAP_H_TILE {
      index:= y * MAP_W_TILE + x
      tile:=gs.tiles[index]
      if tile.type == .dirt{
        draw_rect_aabb(
          tile_pos_to_world_pos(Tile_Coords{x,y}),
          Vector2{TILE_SIZE, TILE_SIZE},
          img_id=.dirt_tile,
          )
      }
    }
  }

  // render player
  for en in gs.entities {
    if .allocated in en.flags {
      #partial switch en.type {
      case .player:
        draw_player(en)
      }
    }
  }

	// alpha :f32= auto_cast math.mod(seconds_since_init() * 0.2, 1.0)
	// xform := xform_rotate(alpha * 360.0)
	// xform *= xform_scale(1.0 + 1 * sine_breathe(alpha))
	// draw_sprite(v2{}, .player, pivot=.bottom_center)
	// draw_sprite(v2{-50, 50}, .crawler, xform=xform, pivot=.center_center)
	draw_text(v2{-200, 100}, "sugon", scale=1.0)
	
	
}

draw_player :: proc(en: Entity) {
  draw_sprite(en.pos, .player, pivot=.bottom_center)
}
