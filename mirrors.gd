extends Node3D

## Two small, real views of the road behind. No capture work outside the cabin.
const UPDATE_INTERVAL := 1.0 / 20.0
var game: Node3D
var views: Array[Dictionary]=[]
var elapsed: float=1.0
var was_active: bool=false
var update_count: int=0
var surface_proof: Array[Dictionary]=[]

func setup(owner_game: Node3D) -> void:
	game=owner_game
	_build_view("Rear mirror",Vector2i(384,102),Vector3(0.0,1.20,1.43),Vector3(0.0,-0.045,1.0),25.0)
	_build_view("Driver mirror",Vector2i(192,120),Vector3(-1.03,1.10,-0.28),Vector3(-0.13,-0.065,1.0),39.0)

func _build_view(label: String, resolution: Vector2i, eye: Vector3, aim: Vector3, fov: float) -> void:
	var viewport:=SubViewport.new()
	viewport.name=label+" render"
	viewport.size=resolution
	viewport.use_hdr_2d=true
	viewport.world_3d=game.get_world_3d()
	viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
	viewport.gui_disable_input=true
	viewport.audio_listener_enable_2d=false
	viewport.audio_listener_enable_3d=false
	viewport.positional_shadow_atlas_size=0
	viewport.use_taa=false
	viewport.msaa_3d=Viewport.MSAA_DISABLED
	viewport.screen_space_aa=Viewport.SCREEN_SPACE_AA_FXAA
	add_child(viewport)
	var rear_camera:=Camera3D.new()
	rear_camera.name=label+" camera"
	rear_camera.fov=fov
	rear_camera.near=0.10
	rear_camera.far=700.0
	# Layer 1 is the proving ground. Car and mirror faces cannot recurse.
	rear_camera.cull_mask=1
	var environment: Environment=game.get_world_3d().environment.duplicate()
	# Keep mirror radiance linear; the main view applies tone mapping once.
	environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	environment.ssao_enabled=false
	environment.ssil_enabled=false
	environment.ssr_enabled=false
	rear_camera.environment=environment
	viewport.add_child(rear_camera)
	rear_camera.current=true
	var shader:=Shader.new()
	shader.code="""shader_type spatial;
render_mode unshaded, cull_back, fog_disabled;
uniform sampler2D mirror_view : filter_linear, repeat_disable;
void vertex() { VERTEX+=NORMAL*0.0007; }
void fragment() {
    vec3 reflected=texture(mirror_view,vec2(1.0-UV.x,UV.y)).rgb;
    ALBEDO=reflected*vec3(0.91,0.95,0.98);
}
"""
	var material:=ShaderMaterial.new()
	material.resource_name=label+" glass"
	material.shader=shader
	material.set_shader_parameter("mirror_view",viewport.get_texture())
	var face:=MeshInstance3D.new()
	face.name=label+" live face"
	var surface: Dictionary=_authored_face(label)
	var source: MeshInstance3D=surface.source
	face.mesh=surface.mesh
	face.material_override=material
	face.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	face.layers=4
	face.visible=false
	game.vehicle.visual.add_child(face)
	face.transform=source.transform
	face.skin=source.skin
	face.skeleton=face.get_path_to(source.get_node(source.skeleton))
	face.extra_cull_margin=source.extra_cull_margin
	views.append({"viewport":viewport,"camera":rear_camera,"face":face,"source":source,"eye":eye,"aim":aim})

func _authored_face(label: String) -> Dictionary:
	var is_driver: bool=label=="Driver mirror"
	var source: MeshInstance3D=game.vehicle.visual.find_child("Mirrors" if is_driver else "Interior",true,false)
	var mesh:=ArrayMesh.new()
	for surface: int in range(source.mesh.get_surface_count()):
		var material: Material=source.mesh.surface_get_material(surface)
		if not is_driver and not "brushed alloy" in material.resource_name.to_lower():
			continue
		var arrays: Array=source.mesh.surface_get_arrays(surface).duplicate(true)
		var positions: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
		var selected:=PackedInt32Array()
		var low:=Vector3(INF,INF,INF)
		var high:=Vector3(-INF,-INF,-INF)
		for offset: int in range(0,indices.size(),3):
			var keep: bool=true
			for corner: int in range(3):
				var vertex: int=indices[offset+corner]
				var p: Vector3=positions[vertex]
				if is_driver:
					# Use the inset back cap of the existing convex housing.
					# The full rounded cap stays attached to the original skin.
					keep=keep and p.x< -0.90 and normals[vertex].z>0.80
				else:
					keep=keep and absf(p.x)<0.102 and p.y>1.234 and p.y<1.296 and p.z> -0.241 and p.z< -0.232 and normals[vertex].z>0.80
			if keep:
				for corner: int in range(3):
					var vertex: int=indices[offset+corner]
					selected.append(vertex)
					low=low.min(positions[vertex])
					high=high.max(positions[vertex])
		if selected.is_empty():
			continue
		var uv:=PackedVector2Array()
		uv.resize(positions.size())
		for vertex: int in range(positions.size()):
			uv[vertex]=Vector2((positions[vertex].x-low.x)/(high.x-low.x),1.0-(positions[vertex].y-low.y)/(high.y-low.y))
		arrays[Mesh.ARRAY_TEX_UV]=uv
		arrays[Mesh.ARRAY_INDEX]=selected
		var flags: int=source.mesh.surface_get_format(surface)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{},flags)
		surface_proof.append({"mirror":label,"source":String(source.name),"source_surface":surface,"triangles":selected.size()/3,"minimum":[low.x,low.y,low.z],"maximum":[high.x,high.y,high.z],"original_positions_normals_skinning_retained":true,"normal_offset_m":0.0007})
	assert(mesh.get_surface_count()>0,"Authored mirror face was not found")
	return {"source":source,"mesh":mesh}

func update_views(dt: float, active: bool) -> void:
	if DisplayServer.get_name()=="headless":
		return
	for view: Dictionary in views:
		view.face.visible=active and view.source.is_visible_in_tree()
	if not active:
		for view: Dictionary in views:
			view.viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
		was_active=false
		return
	elapsed+=dt
	if elapsed<UPDATE_INTERVAL and was_active:
		return
	elapsed=fmod(elapsed,UPDATE_INTERVAL)
	was_active=true
	update_count+=1
	for view: Dictionary in views:
		var capture_camera: Camera3D=view.camera
		capture_camera.global_position=game.vehicle.global_transform*Vector3(view.eye)
		capture_camera.look_at(capture_camera.global_position+game.vehicle.global_basis*Vector3(view.aim),game.vehicle.global_basis.y)
		view.viewport.render_target_update_mode=SubViewport.UPDATE_ONCE
