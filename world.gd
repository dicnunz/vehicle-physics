extends Node3D
class_name ProvingGround

## An original, compact vehicle proving ground. Units are meters.
const SPAWN := Vector3(0.0, 0.0, 15.0)
const RAMP_START := Vector3(0.0, 0.0, -105.0)
const CRASH_LANE_START := Vector3(45.0, 0.0, 5.0)
const CRASH_WALL := Vector3(45.0, 1.0, -70.0)
const BUMP_LANE_START := Vector3(-35.0, 0.0, -15.0)
const SLALOM_START := Vector3(25.0, 0.0, -15.0)

var _concrete: ShaderMaterial
var _asphalt: ShaderMaterial
var _earth: StandardMaterial3D
var _wall: StandardMaterial3D
var _white: StandardMaterial3D
var _yellow: StandardMaterial3D
var _dark: StandardMaterial3D
var _steel: StandardMaterial3D
var _hazard: StandardMaterial3D
var _joint_material: ShaderMaterial
var _paint_white: Array[Vector3] = []
var _paint_yellow: Array[Vector3] = []
var _seams: Array[Vector3] = []
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = 481516
	_materials()
	_main_pad()
	_test_lanes()
	_perimeter_loop()
	# Continuous concrete horizon around the driving areas.
	_workshop()
	_paint_mesh(_paint_white, _road_paint(Color(0.74,0.74,0.68)), "White lane paint")
	_paint_mesh(_paint_yellow, _road_paint(Color(0.80,0.58,0.11)), "Yellow lane paint")
	_paint_mesh(_seams, _joint_material, "Concrete expansion joints")

func _materials() -> void:
	_concrete = _road_material("concrete_floor_02", 0.50, 0.42, Color(0.91,0.90,0.88), 0.070)
	_asphalt = _road_material("asphalt_01", 0.476, 0.90, Color(0.76,0.80,0.85), 0.30)
	_earth = _cc0_pbr("aerial_grass_rock", 0.12, 0.25)
	_wall = _textured("wall", 0.30, 0.90)
	_white = _plain(Color(0.72, 0.72, 0.66), 0.97)
	_yellow = _plain(Color(0.80, 0.58, 0.11), 0.97)
	_dark = _plain(Color(0.21, 0.23, 0.22), 1.0)
	_steel = _plain(Color(0.31, 0.34, 0.34), 0.62)
	_steel.metallic = 0.72
	for paint: StandardMaterial3D in [_white,_yellow]:
		paint.normal_enabled = true
		paint.normal_texture = load("res://assets/world/cc0/asphalt_01_nor_gl_2k.jpg")
		paint.normal_scale = 0.14
		paint.uv1_triplanar = true
		paint.uv1_world_triplanar = true
		paint.uv1_scale = Vector3.ONE * 0.476
	_hazard = _plain(Color.WHITE, 0.91)
	_hazard.albedo_texture = load("res://assets/world/hazard.png")
	_hazard.uv1_triplanar = true
	_hazard.uv1_world_triplanar = true
	_hazard.uv1_scale = Vector3(0.8, 0.8, 0.8)
	var joint_shader := Shader.new()
	joint_shader.code = """shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
varying vec3 world_position;
void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
    float distance_fade = 1.0 - smoothstep(95.0, 380.0, distance(CAMERA_POSITION_WORLD, world_position));
    ALBEDO = vec3(0.13, 0.14, 0.13);
    ALPHA = 0.44 * distance_fade;
}
"""
	_joint_material = ShaderMaterial.new()
	_joint_material.shader = joint_shader

func _road_material(asset: String, scale_value: float, normal_strength: float, tint: Color, variation: float) -> ShaderMaterial:
	var sample_orientation := ""
	var normal_orientation := ""
	if asset.begins_with("concrete"):
		sample_orientation = """    // Preserve grain scale while reflecting each cell's photographed marks.
    vec2 flip_a = step(vec2(0.5),hash_offset(cell_a + vec2(23.4,71.9))) * 2.0 - 1.0;
    vec2 flip_b = step(vec2(0.5),hash_offset(cell_b + vec2(23.4,71.9))) * 2.0 - 1.0;
    vec2 flip_c = step(vec2(0.5),hash_offset(cell_c + vec2(23.4,71.9))) * 2.0 - 1.0;
    uv_a = detail_p * scale_value * flip_a + hash_offset(cell_a);
    uv_b = detail_p * scale_value * flip_b + hash_offset(cell_b);
    uv_c = detail_p * scale_value * flip_c + hash_offset(cell_c);
"""
		normal_orientation = """    // Reflect tangent-space slopes together with their sampled coordinates.
    detail_a.xy *= flip_a;
    detail_b.xy *= flip_b;
    detail_c.xy *= flip_c;
"""
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_back;
uniform sampler2D surface_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D surface_roughness : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float scale_value = 0.476;
uniform float normal_strength = 0.26;
uniform float macro_strength = 0.08;
uniform float concrete_surface = 0.0;
varying vec3 world_position;
varying vec3 world_normal;
float hash_value(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7))) * 43758.5453); }
vec2 hash_offset(vec2 p) { return vec2(hash_value(p),hash_value(p+vec2(91.7,34.6))); }
float noise_value(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash_value(i),hash_value(i+vec2(1,0)),u.x),mix(hash_value(i+vec2(0,1)),hash_value(i+vec2(1,1)),u.x),u.y);
}
void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
    vec2 p = world_position.xz;
    vec3 projection_normal = normalize(world_normal);
    vec3 dominant = abs(projection_normal);
    int projection_face = 0;
    vec3 projection_tangent = vec3(1.0,0.0,0.0);
    // Preserve the existing driving-surface projection. Vertical concrete
    // uses the two axes spanning that face, with a consistent tangent basis.
    if (dominant.x > dominant.y && dominant.x >= dominant.z) {
        float side = sign(projection_normal.x);
        p = vec2(world_position.z * side,world_position.y);
        projection_tangent = vec3(0.0,0.0,side);
        projection_face = 1;
    } else if (dominant.z > dominant.y && dominant.z > dominant.x) {
        float side = sign(projection_normal.z);
        p = vec2(-world_position.x * side,world_position.y);
        projection_tangent = vec3(-side,0.0,0.0);
        projection_face = 2;
    }
    vec2 tile = mat2(vec2(1.0,0.0),vec2(-0.57735,1.15470)) * p * scale_value * 0.82;
    vec2 cell = floor(tile);
    vec2 offset = fract(tile);
    vec2 cell_a;
    vec2 cell_b;
    vec2 cell_c;
    vec3 weights;
    if (offset.x + offset.y < 1.0) {
        cell_a = cell;
        cell_b = cell + vec2(1.0,0.0);
        cell_c = cell + vec2(0.0,1.0);
        weights = vec3(1.0-offset.x-offset.y,offset.x,offset.y);
    } else {
        cell_a = cell + vec2(1.0,1.0);
        cell_b = cell + vec2(0.0,1.0);
        cell_c = cell + vec2(1.0,0.0);
        weights = vec3(offset.x+offset.y-1.0,1.0-offset.x,1.0-offset.y);
    }
    weights = weights * weights;
    weights /= dot(weights,vec3(1.0));
    // A directional finish comes from the photographed concrete itself.
    // Keep the stochastic cells in world meters while stretching its grain
    // along the ramp, and vertically on correctly projected side walls.
    vec2 grain_scale = mix(vec2(1.0),vec2(1.25,0.40),concrete_surface);
    vec2 detail_p = p * grain_scale;
    vec2 uv_a = detail_p * scale_value + hash_offset(cell_a);
    vec2 uv_b = detail_p * scale_value + hash_offset(cell_b);
    vec2 uv_c = detail_p * scale_value + hash_offset(cell_c);
%s    vec3 color_a = texture(surface_albedo,uv_a).rgb;
    vec3 color_b = texture(surface_albedo,uv_b).rgb;
    vec3 color_c = texture(surface_albedo,uv_c).rgb;
    vec3 color_value = color_a * weights.x + color_b * weights.y + color_c * weights.z;
    float luma = dot(color_value,vec3(0.2126,0.7152,0.0722));
    float rough = texture(surface_roughness,uv_a).r * weights.x + texture(surface_roughness,uv_b).r * weights.y + texture(surface_roughness,uv_c).r * weights.z;
    float macro = mix(noise_value(p * 0.026),noise_value(p * 0.073 + vec2(4.6,8.1)),0.36);
    vec3 base_color = mix(color_value,vec3(luma),0.35);
    if (concrete_surface > 0.5) {
        // Retain pores and elongated finish marks while removing the
        // photograph's broad clouds. Match the coarse sample to distance.
        float footprint = 2048.0 * max(length(dFdx(detail_p * scale_value)),length(dFdy(detail_p * scale_value)));
        float coarse_lod = max(7.5,log2(max(footprint,1.0)));
        vec3 coarse_color = textureLod(surface_albedo,uv_a,coarse_lod).rgb * weights.x;
        coarse_color += textureLod(surface_albedo,uv_b,coarse_lod).rgb * weights.y;
        coarse_color += textureLod(surface_albedo,uv_c,coarse_lod).rgb * weights.z;
        float coarse_luma = dot(coarse_color,vec3(0.2126,0.7152,0.0722));
        float concrete_luma = clamp(0.205 + (luma-coarse_luma) * 0.40 + (coarse_luma-0.205) * 0.06,0.13,0.29);
        base_color = vec3(concrete_luma) * vec3(1.012,1.0,0.975);
    }
    float slab_random = hash_value(floor((p+vec2(350.0)) / 2.0));
    float slab_tone = 1.0 + (slab_random - 0.5) * concrete_surface * 0.065;
    vec2 slab_uv = fract((p+vec2(350.0)) / 2.0);
    vec2 slab_edges = min(slab_uv,vec2(1.0)-slab_uv) * 2.0;
    float edge_distance = min(slab_edges.x,slab_edges.y);
    float photo_wear = clamp((0.29-luma) * 3.0 + (rough-0.50) * 2.0,0.0,1.0);
    float edge_wear = mix(noise_value(p * 9.3),photo_wear,concrete_surface);
    float seam_filter = clamp(fwidth(edge_distance),0.003,0.045);
    float joint_width = 0.005 + edge_wear * 0.002 + concrete_surface * edge_wear * edge_wear * 0.010;
    float seam = (1.0-smoothstep(joint_width-seam_filter,joint_width+seam_filter,edge_distance)) * concrete_surface;
    float ground_distance = distance(CAMERA_POSITION_WORLD,world_position);
    float seam_fade = 1.0 - smoothstep(150.0,460.0,ground_distance);
    seam *= seam_fade;
    // Darker, rougher regions of the real map shape uneven seam staining.
    // Wider wear stays local to the joint, with narrow runoff into the slab.
    float joint_age = photo_wear;
    float stain_width = 0.060 + joint_age * 0.20;
    float stain = exp(-edge_distance / stain_width) * (0.25 + joint_age * 0.75) * concrete_surface * seam_fade;
    float flow_distance = (projection_face != 0 ? 1.0-slab_uv.y : slab_uv.y) * 2.0;
    float flow_length = 0.16 + joint_age * 0.85;
    float runoff_threads = smoothstep(0.26,0.80,joint_age);
    float seam_runoff = exp(-flow_distance / flow_length) * runoff_threads * seam_fade;
    float directional_wear = seam_runoff * 0.18 * concrete_surface;
    vec2 wear_warp = vec2(noise_value(p / 19.0),noise_value(p / 17.0 + vec2(8.3,6.1))) * 4.0;
    float broad_patch = smoothstep(0.43,0.70,noise_value((p + wear_warp) / 11.0 + vec2(31.5,17.8)));
    float smaller_patch = smoothstep(0.50,0.75,noise_value((p + wear_warp) / 2.7 + vec2(7.1,24.3)));
    float weathering = (broad_patch * 0.24 + smaller_patch * 0.11) * mix(1.0,0.14,concrete_surface);
    float tire_band = exp(-pow((abs(p.x) - 0.82) / 0.28,2.0)) * smoothstep(-94.0,-78.0,p.y) * (1.0-smoothstep(8.0,19.0,p.y));
    tire_band *= smoothstep(0.30,0.56,noise_value(vec2(p.y * 0.36,4.7))) * (1.0-concrete_surface);
    float joint_contrast = 0.22 + edge_wear * 0.28;
    vec3 pavement_color = base_color * tint.rgb * slab_tone * (1.0 + (macro - 0.5) * macro_strength) * (1.0 - seam * joint_contrast - stain * 0.24 - weathering - tire_band * 0.12 - directional_wear);
    ALBEDO = pavement_color;
    vec3 detail_a = texture(surface_normal,uv_a).xyz * 2.0 - 1.0;
    vec3 detail_b = texture(surface_normal,uv_b).xyz * 2.0 - 1.0;
    vec3 detail_c = texture(surface_normal,uv_c).xyz * 2.0 - 1.0;
%s    vec3 detail_value = normalize(detail_a * weights.x + detail_b * weights.y + detail_c * weights.z);
    if (concrete_surface > 0.5) {
        detail_value = normalize(vec3(detail_value.xy * grain_scale,detail_value.z));
    }
    vec3 normal_value = normalize(world_normal);
    vec3 tangent = abs(normal_value.z) > 0.95 ? vec3(1.0,0.0,0.0) : normalize(cross(normal_value,vec3(0.0,0.0,1.0)));
    if (projection_face != 0) {
        tangent = normalize(projection_tangent-normal_value*dot(projection_tangent,normal_value));
    }
    vec3 bitangent = normalize(cross(normal_value,tangent));
    vec2 edge_direction = step(vec2(0.5),slab_uv) * 2.0 - 1.0;
    vec2 bevel = edge_direction * exp(-slab_edges / 0.024) * concrete_surface * seam_fade * (0.16 + edge_wear * 0.09);
    vec3 bevel_world = vec3(bevel.x,0.0,bevel.y);
    if (projection_face != 0) {
        bevel_world = tangent*bevel.x-bitangent*bevel.y;
    }
    float filtered_normal = normal_strength * mix(1.0,0.42,smoothstep(18.0,75.0,ground_distance));
    vec3 perturbed = normalize(normal_value * detail_value.z + (tangent * detail_value.x + bitangent * detail_value.y) * filtered_normal + bevel_world);
    NORMAL = normalize((VIEW_MATRIX * vec4(perturbed,0.0)).xyz);
    float asphalt_roughness = clamp(0.38 + rough * 0.50 + macro * 0.10 - broad_patch * 0.055,0.64,0.93);
    float concrete_roughness = clamp(0.78 + rough * 0.19 + slab_random * 0.035 + stain * 0.025 - exp(-edge_distance / 0.035) * 0.065,0.80,0.98);
    ROUGHNESS = mix(asphalt_roughness,concrete_roughness,concrete_surface);
    SPECULAR = mix(0.42,0.25,concrete_surface);
}
""" % [sample_orientation, normal_orientation]
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("surface_albedo",load("res://assets/world/cc0/" + asset + "_diff_2k.jpg"))
	material.set_shader_parameter("surface_normal",load("res://assets/world/cc0/" + asset + "_nor_gl_2k.jpg"))
	material.set_shader_parameter("surface_roughness",load("res://assets/world/cc0/" + asset + "_rough_2k.jpg"))
	material.set_shader_parameter("scale_value",scale_value)
	material.set_shader_parameter("normal_strength",normal_strength)
	material.set_shader_parameter("tint",tint)
	material.set_shader_parameter("macro_strength",variation)
	material.set_shader_parameter("concrete_surface",1.0 if asset.begins_with("concrete") else 0.0)
	return material

func _road_paint(color: Color) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode cull_back, depth_prepass_alpha;
uniform sampler2D pavement_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D pavement_rough : filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 paint_color : source_color;
varying vec3 world_position;
void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz; }
void fragment() {
    vec2 p = world_position.xz;
    float grain = texture(pavement_rough,p * 0.476).r;
    float chip = texture(pavement_rough,p * 1.71 + vec2(0.17,0.46)).r;
    float edge = min(UV2.x,UV2.y-UV2.x);
    float worn_edge = smoothstep(0.001,0.004,edge - (1.0-chip) * 0.010);
    ALBEDO = paint_color.rgb * mix(0.74,1.0,grain);
    ROUGHNESS = 0.78 + grain * 0.20;
    NORMAL_MAP = texture(pavement_normal,p * 0.476).rgb;
    NORMAL_MAP_DEPTH = 0.45;
    ALPHA = worn_edge;
    ALPHA_SCISSOR_THRESHOLD = 0.5;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("pavement_normal",load("res://assets/world/cc0/asphalt_01_nor_gl_2k.jpg"))
	material.set_shader_parameter("pavement_rough",load("res://assets/world/cc0/asphalt_01_rough_2k.jpg"))
	material.set_shader_parameter("paint_color",color)
	return material

func _cc0_pbr(asset: String, uv_scale: float, normal_strength: float) -> StandardMaterial3D:
	var material := _plain(Color.WHITE, 0.97)
	material.albedo_texture = load("res://assets/world/cc0/" + asset + "_diff_2k.jpg")
	material.normal_enabled = true
	material.normal_texture = load("res://assets/world/cc0/" + asset + "_nor_gl_2k.jpg")
	material.normal_scale = normal_strength
	var roughness_path: String = "res://assets/world/cc0/" + asset + "_rough_2k.jpg"
	if ResourceLoader.exists(roughness_path):
		material.roughness_texture = load(roughness_path)
	material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * uv_scale
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material

func _plain(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material

func _textured(texture_name: String, scale_value: float, roughness: float) -> StandardMaterial3D:
	var material := _plain(Color.WHITE, roughness)
	material.albedo_texture = load("res://assets/world/" + texture_name + ".png")
	material.normal_enabled = true
	material.normal_texture = load("res://assets/world/" + texture_name + "_normal.png")
	material.normal_scale = 0.55
	material.uv1_triplanar = true
	material.uv1_world_triplanar = true
	material.uv1_scale = Vector3.ONE * scale_value
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material

func _box(label: String, size: Vector3, center: Vector3, material: Material, collision: bool = true, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = label
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material
	instance.position = center
	instance.rotation = rot
	add_child(instance)
	if collision:
		var body := StaticBody3D.new()
		body.name = label + " collision"
		body.position = center
		body.rotation = rot
		body.set_meta("surface", "asphalt")
		var physics_material := PhysicsMaterial.new()
		physics_material.friction = 0.95
		body.physics_material_override = physics_material
		var shape_node := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		shape_node.shape = shape
		body.add_child(shape_node)
		add_child(body)
	return instance

func _main_pad() -> void:
	_box("Concrete proving ground", Vector3(12000.0, 0.8, 12000.0), Vector3(0.0, -0.4, 0.0), _concrete)
	# Concrete joints are shaded once, continuously across the full slab.
	# A continuous clean launch/braking lane connects the driving exercises.
	_box("Primary asphalt lane", Vector3(13.0, 0.028, 250.0), Vector3(0.0, 0.002, -49.0), _asphalt, false)
	for x in [-6.0, 6.0]:
		_rect(_paint_white, Vector3(float(x), 0.022, -24.0), Vector2(0.14, 195.0))
	_rect(_paint_white, Vector3(0.0, 0.023, 21.0), Vector2(11.7, 0.28))
	for z in range(-80, 22, 20):
		_rect(_paint_white, Vector3(-5.6, 0.024, float(z)), Vector2(0.65, 0.12))
		_rect(_paint_white, Vector3(5.6, 0.024, float(z)), Vector2(0.65, 0.12))
	# A broad tire-testing circle leaves room to learn the car.
	_disc(Vector3(-115.0, 0.016, 45.0), 42.0, _asphalt, 96)
	_circle_paint(Vector3(-115.0, 0.032, 45.0), 33.0, 0.14, _paint_white)
	_circle_paint(Vector3(-115.0, 0.032, 45.0), 20.0, 0.12, _paint_white)
	_circle_paint(Vector3(-115.0, 0.032, 45.0), 41.0, 0.18, _paint_yellow)
	# Restrained old tire marks add scale and surface wear.
	var skid_material := _plain(Color(0.16, 0.17, 0.165, 0.35), 1.0)
	skid_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var marks: Array[Vector3] = []
	for index in range(5):
		var radius: float = 19.0 + float(index) * 2.75
		_arc_paint(Vector3(-115.0, 0.036, 45.0), radius, 0.17, 0.3 + float(index) * 0.6, 2.6 + float(index) * 0.6, marks, 42)
	for x in [-0.81, 0.81]:
		_rect(marks, Vector3(float(x), 0.03, -63.0), Vector2(0.21, 17.0))
	_paint_mesh(marks, skid_material, "Weathered tire marks")
	var wear_material := _plain(Color(0.08, 0.085, 0.08, 0.085), 1.0)
	wear_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var wear: Array[Vector3] = []
	for axle_x in [-0.85, 0.85]:
		for index in range(16):
			var z_value: float = 12.0 - float(index) * 6.0
			var lateral: float = float(axle_x) + sin(float(index) * 0.32) * 0.15
			_rect(wear, Vector3(lateral, 0.034, z_value), Vector2(0.24 + sin(float(index)) * 0.035, 6.02))
	for axle_x in [44.15, 45.85]:
		_rect(wear, Vector3(float(axle_x), 0.035, -43.0), Vector2(0.23, 36.0))
	_paint_mesh(wear, wear_material, "Light tire rubber deposits")
	# A few small branching cracks sit in concrete slabs beside the road.
	for index in range(24):
		var origin := Vector3(_rng.randf_range(8.0, 21.0) * (-1.0 if index % 2 == 0 else 1.0), 0.012, _rng.randf_range(-95.0, 28.0))
		var previous: Vector3 = origin
		for segment in range(4):
			var next: Vector3 = previous + Vector3(_rng.randf_range(-0.42, 0.60), 0.0, _rng.randf_range(0.25, 0.72))
			_line(_seams, previous, next, 0.015)
			previous = next

func _test_lanes() -> void:
	# The main progressive launch ramp faces the spawn and rises toward -Z.
	_ramp(Vector3(0.0, 0.0, -105.0), 11.0, 32.0, 7.0)
	_sign("RAMP", Vector3(8.8, 0.0, -91.0), 0.0)
	for x in [-6.7, 6.7]:
		for z in [-101.0, -107.0]:
			_cone(Vector3(float(x), 0.0, float(z)))
	# Long low landing wedge aligned with the launch trajectory.
	_ramp(Vector3(0.0, 0.0, -213.0), 18.0, 32.0, 4.0, PI)
	# Concrete wall test lane.
	_box("Impact approach asphalt", Vector3(15.0, 0.03, 107.0), Vector3(45.0, 0.003, -17.0), _asphalt, false)
	for x in [38.3, 51.7]:
		_rect(_paint_white, Vector3(float(x), 0.024, -18.0), Vector2(0.13, 100.0))
	for z in [-38.0, -46.0, -54.0, -61.0]:
		_rect(_paint_yellow, Vector3(45.0, 0.027, float(z)), Vector2(13.0, 0.16))
	_box("Solid crash barrier", Vector3(14.0, 2.0, 1.4), CRASH_WALL, _wall)
	_box("Crash wall warning band", Vector3(13.9, 0.38, 0.022), Vector3(45.0, 1.62, -69.286), _hazard, false)
	for x in [38.0, 52.0]:
		_box("Barrier return", Vector3(0.6, 0.95, 5.0), Vector3(float(x), 0.475, -72.0), _wall)
	_sign("IMPACT", Vector3(55.6, 0.0, -51.0), 0.0)
	# Low rounded suspension impulses, including staggered left/right blocks.
	_box("Suspension lane asphalt", Vector3(10.0, 0.024, 96.0), Vector3(-35.0, 0.002, -60.0), _asphalt, false)
	for x in [-39.5, -30.5]:
		_rect(_paint_white, Vector3(float(x), 0.024, -60.0), Vector2(0.13, 95.0))
	for i in range(9):
		var z_position: float = -35.0 - float(i) * 6.2
		var width: float = 7.3 if i < 4 else 3.4
		var x_position: float = -35.0 if i < 4 else -35.0 + (1.9 if i % 2 == 0 else -1.9)
		_bump(Vector3(x_position, 0.0, z_position), width, 0.19 if i < 4 else 0.29)
	_sign("SUSPENSION", Vector3(-27.0, 0.0, -25.0), 0.0)
	# Slalom uses visible, low-mass-looking cones with no hidden walls.
	for i in range(8):
		var x_position: float = 25.0 + (-2.6 if i % 2 == 0 else 2.6)
		_cone(Vector3(x_position, 0.0, -30.0 - float(i) * 13.0))
	_sign("SLALOM", Vector3(31.5, 0.0, -18.0), 0.0)
	# A short gravel lane changes both the visual and contact surface.
	_box("Gravel strip", Vector3(14.0, 0.09, 100.0), Vector3(-75.0, -0.015, -126.0), _earth)
	var gravel_body: Node = get_child(get_child_count() - 1)
	gravel_body.set_meta("surface", "gravel")
	_sign("LOOSE SURFACE", Vector3(-65.0, 0.0, -72.0), 0.0)

func _ramp(origin: Vector3, width: float, length: float, height: float, yaw: float = 0.0) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps: int = 32
	for i in range(steps):
		var t0: float = float(i) / float(steps)
		var t1: float = float(i + 1) / float(steps)
		var y0: float = height * t0 * t0 + 0.016
		var y1: float = height * t1 * t1 + 0.016
		var a := Vector3(-width * 0.5, y0, -length * t0)
		var b := Vector3(width * 0.5, y0, -length * t0)
		var c := Vector3(width * 0.5, y1, -length * t1)
		var d := Vector3(-width * 0.5, y1, -length * t1)
		_quad(st, a, b, c, d)
		_quad(st, Vector3(a.x, 0.0, a.z), a, d, Vector3(d.x, 0.0, d.z))
		_quad(st, b, Vector3(b.x, 0.0, b.z), Vector3(c.x, 0.0, c.z), c)
	_quad(st, Vector3(-width * 0.5, 0.0, -length), Vector3(-width * 0.5, height, -length), Vector3(width * 0.5, height, -length), Vector3(width * 0.5, 0.0, -length))
	st.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Progressive concrete ramp"
	mesh_instance.mesh = st.commit()
	mesh_instance.material_override = _concrete
	mesh_instance.position = origin
	mesh_instance.rotation.y = yaw
	add_child(mesh_instance)
	mesh_instance.create_trimesh_collision()
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			child.set_meta("surface", "asphalt")
	# Narrow painted stripes follow the actual curved ramp surface.
	var stripe_st := SurfaceTool.new()
	stripe_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		for i in range(steps):
			var t0: float = float(i) / float(steps)
			var t1: float = float(i + 1) / float(steps)
			var x_value: float = float(side) * (width * 0.5 - 0.26)
			_quad(stripe_st, Vector3(x_value - 0.07, height * t0 * t0 + 0.03, -length * t0), Vector3(x_value + 0.07, height * t0 * t0 + 0.03, -length * t0), Vector3(x_value + 0.07, height * t1 * t1 + 0.03, -length * t1), Vector3(x_value - 0.07, height * t1 * t1 + 0.03, -length * t1))
	stripe_st.generate_normals()
	var stripes := MeshInstance3D.new()
	stripes.name = "Ramp edge paint"
	stripes.mesh = stripe_st.commit()
	stripes.material_override = _yellow
	stripes.position = origin
	stripes.rotation.y = yaw
	add_child(stripes)

func _bump(origin: Vector3, width: float, height: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(12):
		var t0: float = float(i) / 12.0
		var t1: float = float(i + 1) / 12.0
		var y0: float = sin(t0 * PI) * height + 0.018
		var y1: float = sin(t1 * PI) * height + 0.018
		_quad(st, Vector3(-width * 0.5, y0, -t0 * 1.3), Vector3(width * 0.5, y0, -t0 * 1.3), Vector3(width * 0.5, y1, -t1 * 1.3), Vector3(-width * 0.5, y1, -t1 * 1.3))
	st.generate_normals()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Rounded suspension bump"
	mesh_instance.mesh = st.commit()
	mesh_instance.material_override = _yellow
	mesh_instance.position = origin
	add_child(mesh_instance)
	mesh_instance.create_trimesh_collision()
	for child in mesh_instance.get_children():
		if child is StaticBody3D:
			child.set_meta("surface", "asphalt")

func _perimeter_loop() -> void:
	var centers: Array[Vector2] = [Vector2(165.0, 195.0), Vector2(-165.0, 195.0), Vector2(-165.0, -195.0), Vector2(165.0, -195.0)]
	var path: Array[Vector3] = []
	for corner in range(4):
		var start_angle: float = float(corner) * PI * 0.5
		for step in range(19):
			var angle: float = start_angle + float(step) / 18.0 * PI * 0.5
			var center: Vector2 = centers[corner]
			path.append(Vector3(center.x + cos(angle) * 68.0, 0.035, center.y + sin(angle) * 68.0))
	# Flat asphalt loop shares the primary slab collision plane.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count: int = path.size()
	for i in range(count):
		var j: int = (i + 1) % count
		var previous: Vector3 = path[(i - 1 + count) % count]
		var after: Vector3 = path[(j + 1) % count]
		var tangent_a: Vector3 = (path[j] - previous).normalized()
		var tangent_b: Vector3 = (after - path[i]).normalized()
		var right_a: Vector3 = tangent_a.cross(Vector3.UP).normalized()
		var right_b: Vector3 = tangent_b.cross(Vector3.UP).normalized()
		_quad(st, path[i] - right_a * 9.0, path[i] + right_a * 9.0, path[j] + right_b * 9.0, path[j] - right_b * 9.0)
		for side in [-1.0, 1.0]:
			var edge_a: Vector3 = path[i] + right_a * float(side) * 8.25 + Vector3.UP * 0.006
			var edge_b: Vector3 = path[j] + right_b * float(side) * 8.25 + Vector3.UP * 0.006
			_line(_paint_white, edge_a, edge_b, 0.16)
		var segment_length: float = path[i].distance_to(path[j])
		var dash_count: int = maxi(1, int(segment_length / 10.0))
		for dash in range(dash_count):
			var ta: float = (float(dash) + 0.15) / float(dash_count)
			var tb: float = (float(dash) + 0.55) / float(dash_count)
			_line(_paint_yellow, path[i].lerp(path[j], ta) + Vector3.UP * 0.007, path[i].lerp(path[j], tb) + Vector3.UP * 0.007, 0.12)
	st.generate_normals()
	var road := MeshInstance3D.new()
	road.name = "Perimeter handling circuit"
	road.mesh = st.commit()
	road.material_override = _asphalt
	add_child(road)
	# Short guardrail on the outside of the far straight.
	for i in range(22):
		var x_value: float = -145.0 + float(i) * 14.0
		_box("Guardrail beam", Vector3(14.0, 0.34, 0.14), Vector3(x_value, 0.78, -278.0), _steel)
		_box("Guardrail post", Vector3(0.12, 1.08, 0.15), Vector3(x_value, 0.54, -278.02), _steel, false)
	# A few jersey blocks delimit the workshop access apron.
	for i in range(8):
		_jersey(Vector3(115.0 + float(i) * 4.2, 0.0, 161.0), 0.0)

func _workshop() -> void:
	var roof_material := _plain(Color(0.27, 0.29, 0.28), 0.8)
	var door_material := _plain(Color(0.30, 0.35, 0.36), 0.82)
	_box("Workshop concrete foundation", Vector3(54.0, 0.25, 28.0), Vector3(130.0, 0.125, 189.0), _concrete)
	_box("Workshop rear wall", Vector3(52.0, 7.0, 0.4), Vector3(130.0, 3.75, 202.0), _wall)
	for x in [104.0, 156.0]:
		_box("Workshop side wall", Vector3(0.4, 7.0, 26.0), Vector3(float(x), 3.75, 189.0), _wall)
	_box("Workshop roof", Vector3(55.0, 0.35, 29.0), Vector3(130.0, 7.39, 188.7), roof_material)
	_box("Workshop front lintel", Vector3(52.0, 1.3, 0.5), Vector3(130.0, 6.58, 176.0), _wall)
	for x in [104.0, 117.0, 130.0, 143.0, 156.0]:
		_box("Workshop bay pillar", Vector3(0.7, 5.5, 0.7), Vector3(float(x), 3.0, 176.0), _wall)
	for x in [110.5, 123.5, 149.5]:
		_box("Closed roller door", Vector3(11.6, 5.7, 0.14), Vector3(float(x), 3.1, 176.2), door_material)
		for y in range(10):
			_box("Roller door seam", Vector3(11.5, 0.035, 0.016), Vector3(float(x), 0.5 + float(y) * 0.54, 176.12), _steel, false)
	# One open bay has a dark, collision-correct interior.
	_box("Open bay side wall", Vector3(0.25, 5.8, 24.0), Vector3(130.0, 3.1, 188.0), _wall)
	for i in range(9):
		var x_value: float = 92.0 + float(i) * 6.0
		_rect(_paint_white, Vector3(x_value, 0.019, 158.0), Vector2(0.12, 9.0))
	# Low utility fixtures contribute believable dimensions at minimal cost.
	for center in [Vector3(85.0, 0.0, 195.0), Vector3(176.0, 0.0, 195.0), Vector3(-150.0, 0.0, -180.0)]:
		_box("Light pole", Vector3(0.18, 11.0, 0.18), center + Vector3.UP * 5.5, _steel, false)
		_box("Light pole base", Vector3(0.9, 0.55, 0.9), center + Vector3.UP * 0.275, _wall)
		_box("Floodlight bar", Vector3(2.5, 0.12, 0.15), center + Vector3.UP * 11.0, _steel, false)
		for side in [-0.85, 0.85]:
			_box("Floodlight", Vector3(0.62, 0.22, 0.45), center + Vector3(float(side), 11.0, -0.17), _dark, false, Vector3(-0.25, 0.0, 0.0))

func _cone(origin: Vector3) -> void:
	var body := RigidBody3D.new()
	body.name = "Movable traffic cone"
	body.position = origin
	body.mass = 1.8
	body.linear_damp = 0.25
	body.angular_damp = 0.7
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3(0.0, 0.12, 0.0)
	body.set_meta("surface", "plastic")
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.72
	physics_material.bounce = 0.08
	body.physics_material_override = physics_material
	var base := MeshInstance3D.new()
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(0.52, 0.045, 0.52)
	base.mesh = base_mesh
	base.material_override = _dark
	base.position.y = 0.0225
	body.add_child(base)
	var orange := _plain(Color(0.91, 0.23, 0.045), 0.84)
	for part in range(3):
		var y_bottom: float = 0.045 + float(part) * 0.215
		var cone := CylinderMesh.new()
		cone.bottom_radius = 0.195 - float(part) * 0.052
		cone.top_radius = 0.195 - float(part + 1) * 0.052
		cone.height = 0.215
		cone.radial_segments = 12
		var instance := MeshInstance3D.new()
		instance.name = "Traffic cone shell"
		instance.mesh = cone
		instance.material_override = _white if part == 1 else orange
		instance.position.y = y_bottom + 0.1075
		body.add_child(instance)
	var shape_node := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	var points := PackedVector3Array()
	for index in range(8):
		var angle: float = float(index) / 8.0 * TAU
		points.append(Vector3(cos(angle) * 0.24, 0.0, sin(angle) * 0.24))
		points.append(Vector3(cos(angle) * 0.04, 0.69, sin(angle) * 0.04))
	shape.points = points
	shape_node.shape = shape
	body.add_child(shape_node)
	add_child(body)

func _jersey(origin: Vector3, yaw: float) -> void:
	var points: Array[Vector2] = [Vector2(-0.40, 0.0), Vector2(-0.36, 0.20), Vector2(-0.13, 0.61), Vector2(-0.10, 1.03), Vector2(0.10, 1.03), Vector2(0.13, 0.61), Vector2(0.36, 0.20), Vector2(0.40, 0.0)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(points.size()):
		var next: int = (index + 1) % points.size()
		var a: Vector2 = points[index]
		var b: Vector2 = points[next]
		_quad(st, Vector3(-1.9, a.y, a.x), Vector3(1.9, a.y, a.x), Vector3(1.9, b.y, b.x), Vector3(-1.9, b.y, b.x))
	for side in [-1.0, 1.0]:
		for index in range(1, points.size() - 1):
			var a := Vector3(float(side) * 1.9, points[0].y, points[0].x)
			var b := Vector3(float(side) * 1.9, points[index].y, points[index].x)
			var c := Vector3(float(side) * 1.9, points[index + 1].y, points[index + 1].x)
			_tri(st, a, b, c) if side > 0.0 else _tri(st, c, b, a)
	st.generate_normals()
	var instance := MeshInstance3D.new()
	instance.name = "Jersey safety barrier"
	instance.mesh = st.commit()
	instance.material_override = _wall
	instance.position = origin
	instance.rotation.y = yaw
	add_child(instance)
	instance.create_trimesh_collision()

func _sign(text_value: String, origin: Vector3, yaw: float) -> void:
	var root := Node3D.new()
	root.name = text_value + " sign"
	root.position = origin
	root.rotation.y = yaw
	add_child(root)
	var post := MeshInstance3D.new()
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.07, 2.1, 0.07)
	post.mesh = post_mesh
	post.material_override = _steel
	post.position.y = 1.05
	root.add_child(post)
	var board := MeshInstance3D.new()
	var board_mesh := BoxMesh.new()
	board_mesh.size = Vector3(2.6, 0.65, 0.04)
	board.mesh = board_mesh
	board.material_override = _plain(Color(0.17, 0.21, 0.22), 0.85)
	board.position.y = 2.0
	root.add_child(board)
	var label := Label3D.new()
	label.text = text_value
	label.font_size = 48
	label.pixel_size = 0.0043
	label.outline_size = 0
	label.modulate = Color(0.9, 0.91, 0.87)
	label.no_depth_test = false
	label.position = Vector3(0.0, 2.0, 0.023)
	root.add_child(label)

func _disc(center: Vector3, radius: float, material: Material, segments: int) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(segments):
		var a: float = float(index) / float(segments) * TAU
		var b: float = float(index + 1) / float(segments) * TAU
		_tri(st, center, center + Vector3(cos(b) * radius, 0.0, sin(b) * radius), center + Vector3(cos(a) * radius, 0.0, sin(a) * radius))
	st.generate_normals()
	var instance := MeshInstance3D.new()
	instance.name = "Circular handling pad"
	instance.mesh = st.commit()
	instance.material_override = material
	add_child(instance)

func _circle_paint(center: Vector3, radius: float, width: float, destination: Array[Vector3]) -> void:
	_arc_paint(center, radius, width, 0.0, TAU, destination, 128)

func _arc_paint(center: Vector3, radius: float, width: float, start: float, finish: float, destination: Array[Vector3], segments: int) -> void:
	for index in range(segments):
		var angle_a: float = lerpf(start, finish, float(index) / float(segments))
		var angle_b: float = lerpf(start, finish, float(index + 1) / float(segments))
		_line(destination, center + Vector3(cos(angle_a) * radius, 0.0, sin(angle_a) * radius), center + Vector3(cos(angle_b) * radius, 0.0, sin(angle_b) * radius), width)

func _line(destination: Array[Vector3], a: Vector3, b: Vector3, width: float) -> void:
	var side: Vector3 = (b - a).cross(Vector3.UP).normalized() * width * 0.5
	_add_quad(destination, a - side, a + side, b + side, b - side)

func _rect(destination: Array[Vector3], center: Vector3, size: Vector2) -> void:
	_add_quad(destination, center + Vector3(-size.x * 0.5, 0.0, size.y * 0.5), center + Vector3(size.x * 0.5, 0.0, size.y * 0.5), center + Vector3(size.x * 0.5, 0.0, -size.y * 0.5), center + Vector3(-size.x * 0.5, 0.0, -size.y * 0.5))

func _add_quad(destination: Array[Vector3], a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	destination.append_array([a, c, b, a, d, c])

func _paint_mesh(vertices: Array[Vector3], material: Material, label: String) -> void:
	if vertices.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var unit_uv: Array[Vector2] = [Vector2(0,0),Vector2(1,1),Vector2(1,0),Vector2(0,0),Vector2(0,1),Vector2(1,1)]
	for group_index in range(0,vertices.size(),6):
		var width: float = vertices[group_index].distance_to(vertices[group_index+2])
		var length: float = vertices[group_index].distance_to(vertices[group_index+4])
		var short_side: float = minf(width,length)
		for corner in range(6):
			var vertex: Vector3 = vertices[group_index+corner]
			var across: float = unit_uv[corner].x if width <= length else unit_uv[corner].y
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(vertex.x, vertex.z))
			st.set_uv2(Vector2(across * short_side,short_side))
			st.add_vertex(vertex)
	st.generate_tangents()
	var instance := MeshInstance3D.new()
	instance.name = label
	instance.mesh = st.commit()
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	for vertex in [a, c, b]:
		st.set_uv(Vector2(vertex.x, vertex.z))
		st.add_vertex(vertex)
