extends Node3D

var vehicle: SimVehicle
var camera: Camera3D
var hud: Control
var slow_motion: bool=false
var paused: bool=false
var camera_mode: int=0
var orbit_yaw: float=0.0
var orbit_pitch: float=0.2
var orbit_drag: bool=false
var camera_snap: bool=true
var pause_panel: Control
var qa: Node
var skid_nodes: Array=[]
var skid_timer: float=0
var skid_previous: Array[Vector3]=[Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var skid_previous_side: Array[Vector3]=[Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var skid_material: ShaderMaterial
var engine_audio: AudioStreamPlayer
var tire_audio: AudioStreamPlayer
var crash_audio: AudioStreamPlayer
var scene_reflections: ReflectionProbe
var reflection_origin: Vector3=Vector3.INF
var presentation_materials_ready: bool=false

func _ready() -> void:
	if DisplayServer.get_name()!="headless":
		RenderingServer.frame_post_draw.connect(func(): DisplayServer.window_set_title("Vehicle Physics"),CONNECT_ONE_SHOT)
	process_mode=Node.PROCESS_MODE_ALWAYS
	Engine.max_fps=0
	get_window().size_changed.connect(_configure_render_resolution)
	_configure_render_resolution()
	_setup_inputs()
	_environment()
	var ground: Node3D=load("res://world.gd").new()
	ground.name="TestGround"
	add_child(ground)
	vehicle=load("res://vehicle.gd").new()
	vehicle.name="Sedan"
	vehicle.position=Vector3(0,0.15,15)
	add_child(vehicle)
	camera=Camera3D.new()
	camera.fov=65
	camera.near=0.18
	camera.far=2600
	add_child(camera)
	camera.current=true
	var layer: CanvasLayer=CanvasLayer.new()
	add_child(layer)
	hud=load("res://hud.gd").new()
	hud.vehicle=vehicle
	layer.add_child(hud)
	_pause_menu(layer)
	_setup_audio()
	vehicle.collided.connect(_impact_sound)
	qa=load("res://gauntlet.gd").new()
	qa.game=self
	add_child(qa)

func _configure_render_resolution() -> void:
	if DisplayServer.get_name()=="headless":
		return
	var size: Vector2=Vector2(get_window().size)
	var scale: float=minf(1.0,minf(1440.0/maxf(size.x,1.0),900.0/maxf(size.y,1.0)))
	var viewport: Viewport=get_viewport()
	var upscale: bool=scale<0.999
	if upscale:
		viewport.scaling_3d_mode=Viewport.SCALING_3D_MODE_METALFX_TEMPORAL if RenderingServer.get_current_rendering_driver_name()=="metal" else Viewport.SCALING_3D_MODE_FSR2
	else:
		viewport.scaling_3d_mode=Viewport.SCALING_3D_MODE_BILINEAR
	viewport.use_taa=not upscale
	viewport.scaling_3d_scale=scale

func _environment() -> void:
	var sun: DirectionalLight3D=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-47.9,-34.2,0)
	sun.light_color=Color(1,0.97,0.93)
	sun.light_energy=1.45
	sun.light_specular=1.0
	sun.shadow_enabled=true
	sun.light_angular_distance=0.5
	sun.directional_shadow_max_distance=1800
	sun.directional_shadow_mode=DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_bias=0.04
	sun.shadow_normal_bias=0.4
	sun.directional_shadow_split_1=0.013333333
	sun.directional_shadow_split_2=0.055555556
	sun.directional_shadow_split_3=0.28
	add_child(sun)
	var ambient: WorldEnvironment=WorldEnvironment.new()
	var environment: Environment=Environment.new()
	environment.background_mode=Environment.BG_SKY
	var sky: Sky=Sky.new()
	var atmosphere: PanoramaSkyMaterial=PanoramaSkyMaterial.new()
	atmosphere.panorama=load("res://assets/sky/daylight.hdr")
	atmosphere.energy_multiplier=0.80
	sky.sky_material=atmosphere
	sky.radiance_size=Sky.RADIANCE_SIZE_512
	environment.sky=sky
	environment.ambient_light_source=Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color=Color(0.61,0.67,0.75)
	environment.ambient_light_energy=0.42
	environment.tonemap_mode=Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure=1.0
	environment.fog_enabled=true
	environment.fog_light_color=Color(0.69,0.77,0.81)
	environment.fog_density=0.00009
	environment.fog_sky_affect=0.1
	environment.ssao_enabled=true
	environment.ssao_radius=0.4
	environment.ssao_intensity=1.25
	environment.ssao_power=1.25
	environment.ssao_detail=0.65
	environment.ssao_light_affect=0.10
	ambient.environment=environment
	add_child(ambient)
	scene_reflections=ReflectionProbe.new()
	scene_reflections.name="Vehicle environment reflections"
	scene_reflections.size=Vector3(72,32,72)
	scene_reflections.max_distance=2200
	scene_reflections.cull_mask=1
	scene_reflections.reflection_mask=2
	scene_reflections.box_projection=false
	scene_reflections.enable_shadows=false
	scene_reflections.ambient_mode=ReflectionProbe.AMBIENT_DISABLED
	scene_reflections.update_mode=ReflectionProbe.UPDATE_ONCE
	add_child(scene_reflections)

func _vehicle_presentation(node: Node, materials: Dictionary) -> void:
	if node is MeshInstance3D:
		var instance: MeshInstance3D=node
		_refine_panel_shading(instance)
		# The probe captures the shared scene while excluding the car itself.
		instance.layers=2
		for index: int in range(instance.mesh.get_surface_count()):
			var source: Material=instance.get_active_material(index)
			if not source is StandardMaterial3D:
				continue
			if not materials.has(source):
				var material: StandardMaterial3D=source.duplicate()
				var label: String=source.resource_name.to_lower()
				if "paint" in label:
					material.clearcoat_enabled=true
					material.clearcoat=1.0
					material.clearcoat_roughness=0.16
					material.roughness=0.78 if material.roughness_texture else 0.17
					material.metallic=0.25
					material.albedo_color=Color(0.20,0.32,0.39)
				elif "mirror" in label:
					material.transparency=BaseMaterial3D.TRANSPARENCY_DISABLED
					material.albedo_color=Color(0.86,0.88,0.90)
					material.metallic=1.0
					material.roughness=0.025
					material.clearcoat_enabled=false
				elif "glass" in label or "windshield" in label:
					material.clearcoat_enabled=false
					material.clearcoat=0.80
					material.clearcoat_roughness=0.025
					material.metallic_specular=0.52
					material.metallic=0.0
					material.roughness=0.018
					# Side and rear panes share this GLB material; retain its authored alpha.
				elif "wheel alloy" in label:
					material.albedo_color=Color(0.43,0.45,0.48)
					material.metallic=0.82
					material.roughness=0.32
				elif "brushed alloy" in label:
					material.albedo_color=Color(0.40,0.415,0.43)
					material.roughness=0.17
				elif "black trim" in label:
					material.roughness_texture=null
					material.roughness=0.62
					material.metallic=0.0
					material.metallic_specular=0.50
					material.normal_scale=0.18
					material.albedo_color=Color(0.012,0.012,0.011).linear_to_srgb()
				elif "dashboard vinyl" in label:
					material.albedo_color=Color(0.28,0.286,0.29)
					material.metallic=0.0
					material.metallic_specular=0.30
					material.roughness=0.95 if material.roughness_texture else 0.72
					material.normal_scale=0.18
				elif "rubber" in label or "window seals" in label:
					material.metallic_specular=0.42
					material.roughness=0.98 if material.roughness_texture else 0.88
					material.metallic=0.0
					material.normal_scale=0.40
				elif "light lens" in label or "indicator lens" in label:
					material.clearcoat_enabled=true
					material.clearcoat=0.70
					material.clearcoat_roughness=0.13
					material.normal_enabled=true
					material.normal_texture=load("res://assets/world/vehicle_optics_normal.png")
					material.normal_scale=0.45
					material.roughness=0.24
				# Keep the newly authored cabin polymers restrained after GLB import.
				if label in ["molded charcoal steering spokes","charcoal steering grip"]:
					material.normal_scale=0.006 if "spokes" in label else 0.020
					material.roughness=0.84 if "spokes" in label else 0.82
					material.metallic_specular=0.23
					material.clearcoat_enabled=false
				elif label=="matte dark interior housing":
					material.normal_scale=0.012
					material.roughness=0.88
					material.metallic_specular=0.20
					material.clearcoat_enabled=false
				# Preserve the new cabin's baked UV2 cavities and fine authored grain.
				var cabin_specular: Dictionary={
					"fine-grain molded upper vinyl":0.30,"fine-grain lower trim polymer":0.26,
					"woven cloth door trim":0.16,"woven headlining and visors":0.14,
					"molded pillar covering":0.25,"recessed satin control polymer":0.28,
					"satin molded fascia edges":0.30,"dark matte cabin casing":0.20,
					"molded steering grip polymer":0.22,"molded steering horn and spokes":0.23}
				if cabin_specular.has(label):
					material.metallic_specular=cabin_specular[label]
					material.ao_light_affect=0.22
					material.ao_on_uv2=true
					material.clearcoat_enabled=false
				materials[source]=material
				# The new cabin materials retain correlated photographed grain and roughness.
				var imported_metadata: Variant=source.get_meta("extras",{})
				if imported_metadata is Dictionary and imported_metadata.has("cabin_surface"):
					var settings: Dictionary=imported_metadata.cabin_surface.duplicate(true)
					var cabin_finishes: Dictionary={
						"melange cabin door textile":{"tint_linear":[0.2,0.173,0.132],"roughness_range":[0.9,0.99],"specular":0.14,"normal_strength":0.5,"grain_uv_scale_multiplier":0.85,"color_variation":0.8},
						"grained charcoal cabin vinyl":{"tint_linear":[0.055,0.055,0.052],"roughness_range":[0.57,0.74],"specular":0.5,"normal_strength":0.2,"grain_uv_scale_multiplier":1.6},
						"grained warm cabin polymer":{"tint_linear":[0.145,0.13,0.108],"roughness_range":[0.67,0.82],"specular":0.4,"normal_strength":0.12,"grain_uv_scale_multiplier":1.2},
						"textured cabin control polymer":{"tint_linear":[0.022,0.024,0.025],"roughness_range":[0.38,0.54],"specular":0.5,"normal_strength":0.07,"grain_uv_scale_multiplier":1.6},
						"textured dark cabin housing":{"tint_linear":[0.009,0.01,0.012],"roughness_range":[0.74,0.9],"specular":0.35,"normal_strength":0.07,"grain_uv_scale_multiplier":1.4},
						"satin cabin control molding":{"tint_linear":[0.055,0.064,0.066],"roughness_range":[0.4,0.56],"specular":0.5,"normal_strength":0.08},
						"formed satin cabin control molding":{"tint_linear":[0.04,0.044,0.046],"roughness_range":[0.34,0.49],"specular":0.5,"normal_strength":0.06,"grain_uv_scale_multiplier":1.5},
						"cambered cabin ventilation polymer":{"tint_linear":[0.012,0.016,0.018],"roughness_range":[0.59,0.77],"specular":0.46,"normal_strength":0.08},
						"recessed cabin radio seal":{"tint_linear":[0.016,0.019,0.02],"roughness_range":[0.76,0.94],"specular":0.48,"normal_strength":0.12},
						"grained cabin steering grip":{"tint_linear":[0.015,0.016,0.015],"roughness_range":[0.48,0.67],"specular":0.5,"normal_strength":0.2,"grain_uv_scale_multiplier":1.8},
						"grained cabin steering horn":{"tint_linear":[0.063,0.066,0.066],"roughness_range":[0.68,0.86],"specular":0.5,"normal_strength":0.16},
						"compound molded steering horn cushion":{"tint_linear":[0.029,0.03,0.027],"roughness_range":[0.65,0.81],"specular":0.35,"normal_strength":0.26,"grain_uv_scale_multiplier":1.25},
						"satin molded steering spokes":{"tint_linear":[0.05,0.056,0.06],"roughness_range":[0.35,0.5],"specular":0.5,"normal_strength":0.055,"grain_uv_scale_multiplier":1.5},
						"recessed steering cushion carrier":{"tint_linear":[0.009,0.011,0.012],"roughness_range":[0.6,0.78],"specular":0.5,"normal_strength":0.1}}
					settings.merge(cabin_finishes.get(label,{}),true)
					var cabin_surface:=ShaderMaterial.new()
					cabin_surface.resource_name=source.resource_name
					cabin_surface.shader=load("res://assets/vehicle/cabin_surface.gdshader")
					var tint: Array=settings.tint_linear
					cabin_surface.set_shader_parameter("surface_tint",Color(tint[0],tint[1],tint[2]).linear_to_srgb())
					cabin_surface.set_shader_parameter("grain_color",source.albedo_texture)
					cabin_surface.set_shader_parameter("grain_normal",source.normal_texture)
					cabin_surface.set_shader_parameter("grain_roughness",source.roughness_texture)
					cabin_surface.set_shader_parameter("contact_ao",source.ao_texture)
					cabin_surface.set_shader_parameter("grain_uv_scale",Vector2(source.uv1_scale.x,source.uv1_scale.y)*float(settings.get("grain_uv_scale_multiplier",1.0)))
					cabin_surface.set_shader_parameter("roughness_range",Vector2(settings.roughness_range[0],settings.roughness_range[1]))
					for parameter: String in ["normal_strength","color_variation","color_coarse_lod","normal_coarse_lod"]:
						cabin_surface.set_shader_parameter(parameter,settings[parameter])
					cabin_surface.set_shader_parameter("surface_specular",settings.specular)
					materials[source]=cabin_surface
			instance.set_surface_override_material(index,materials[source])
			if String(instance.name) in ["Wheel_FL_Mesh","Wheel_FR_Mesh","Wheel_RL_Mesh","Wheel_RR_Mesh"] and source.resource_name=="Tire rubber":
				var dry_tire: StandardMaterial3D=materials[source].duplicate()
				dry_tire.albedo_color=Color(0.027,0.027,0.025).linear_to_srgb()
				dry_tire.roughness=0.85
				dry_tire.metallic_specular=0.50
				instance.set_surface_override_material(index,dry_tire)
			if instance.name=="Roof" and "paint" in source.resource_name.to_lower():
				var roof_material: StandardMaterial3D=materials[source].duplicate()
				var lining_shader:=Shader.new()
				lining_shader.code="""shader_type spatial;
render_mode cull_back;
uniform sampler2D fabric_normal : hint_normal, filter_linear_mipmap, repeat_enable;
varying float underside;
void vertex() { underside=step(NORMAL.y,-0.35); }
void fragment() {
    if (underside<0.5) { discard; }
    ALBEDO=vec3(0.180,0.174,0.157);
    ROUGHNESS=0.98;
    SPECULAR=0.12;
    NORMAL_MAP=texture(fabric_normal,UV*3.0).rgb;
    NORMAL_MAP_DEPTH=0.18;
}
"""
				var lining:=ShaderMaterial.new()
				lining.resource_name="Matte woven headliner"
				lining.shader=lining_shader
				for original: Material in materials:
					if "seat fabric" in original.resource_name.to_lower():
						lining.set_shader_parameter("fabric_normal",original.normal_texture)
				roof_material.next_pass=lining
				instance.set_surface_override_material(index,roof_material)
	for child: Node in node.get_children():
		_vehicle_presentation(child,materials)

func _refine_panel_shading(instance: MeshInstance3D) -> void:
	var label: String=instance.name
	if not (label.begins_with("Door_") or label.begins_with("Quarter_") or label.begins_with("Fender_")):
		return
	var replacement:=ArrayMesh.new()
	for surface: int in range(instance.mesh.get_surface_count()):
		var arrays: Array=instance.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
		var original_normals: PackedVector3Array=normals.duplicate()
		var tangents: PackedFloat32Array=arrays[Mesh.ARRAY_TANGENT]
		for index: int in range(vertices.size()):
			var p: Vector3=vertices[index]
			var seam_distance: float=minf(absf(p.z-1.168),minf(absf(p.z-0.486),absf(p.z+0.658)))
			if seam_distance>0.014 or signf(p.x)*original_normals[index].x<0.6:
				continue
			var best: int=-1
			var best_distance: float=INF
			for candidate: int in range(vertices.size()):
				var offset: Vector3=vertices[candidate]-p
				if absf(offset.z)<0.025 or absf(offset.z)>0.095 or p.x*original_normals[candidate].x<0.75 or absf(offset.y)>0.02 or absf(offset.x)>0.02:
					continue
				var distance_value: float=offset.x*offset.x+offset.y*offset.y*4.0+offset.z*offset.z*0.1
				if distance_value<best_distance:
					best_distance=distance_value
					best=candidate
			if best<0:
				continue
			# Keep the exterior sheet smooth across the folded panel edge.
			# Positions and all skinning data are retained exactly.
			normals[index]=original_normals[best]
			if tangents.size()==vertices.size()*4:
				var tangent:=Vector3(tangents[index*4],tangents[index*4+1],tangents[index*4+2])
				tangent=(tangent-normals[index]*tangent.dot(normals[index])).normalized()
				tangents[index*4]=tangent.x
				tangents[index*4+1]=tangent.y
				tangents[index*4+2]=tangent.z
		arrays[Mesh.ARRAY_NORMAL]=normals
		arrays[Mesh.ARRAY_TANGENT]=tangents
		var flags: int=instance.mesh.surface_get_format(surface) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{},flags)
		replacement.surface_set_material(surface,instance.mesh.surface_get_material(surface))
	instance.mesh=replacement

func _update_scene_reflections() -> void:
	if not presentation_materials_ready:
		_vehicle_presentation(vehicle.visual,{})
		presentation_materials_ready=true
	if reflection_origin.distance_squared_to(vehicle.global_position)>100.0:
		reflection_origin=vehicle.global_position
		scene_reflections.global_position=reflection_origin+Vector3.UP*1.1

func _setup_inputs() -> void:
	var debug_log: String=OS.get_environment("PROVING_GROUND_INPUT_DEBUG_LOG")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--input-debug-log="):
			debug_log=argument.trim_prefix("--input-debug-log=")
	if not debug_log.is_empty():
		debug_log=ProjectSettings.globalize_path(debug_log)
	set_meta("input_debug_log",debug_log)
	var actions: Dictionary={"accelerate":[KEY_W,KEY_UP],"brake_reverse":[KEY_S,KEY_DOWN],"left":[KEY_A,KEY_LEFT],"right":[KEY_D,KEY_RIGHT],"handbrake":[KEY_SPACE],"reset":[KEY_R],"camera":[KEY_TAB,KEY_C],"slow":[KEY_J],"pause":[KEY_ESCAPE],"fps":[KEY_F3]}
	for action: String in actions:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key: int in actions[action]:
			var event: InputEventKey=InputEventKey.new()
			event.physical_keycode=key
			InputMap.action_add_event(action,event)
	if not debug_log.is_empty():
		DirAccess.make_dir_recursive_absolute(debug_log.get_base_dir())
		var file: FileAccess=FileAccess.open(debug_log,FileAccess.WRITE)
		file.store_line(JSON.stringify({"stage":"bindings","ticks_ms":Time.get_ticks_msec(),"actions":actions,"physical_bindings":true,"runtime":OS.get_executable_path()}))
		file.close()

func _input(event: InputEvent) -> void:
	var debug_log: String=get_meta("input_debug_log","")
	if debug_log.is_empty() or not (event is InputEventKey or event is InputEventMouseButton):
		return
	var matched: Array[String]=[]
	for action: String in ["accelerate","brake_reverse","left","right","handbrake","reset","camera","slow","pause","fps"]:
		if event.is_action(action):matched.append(action)
	var record: Dictionary={"stage":"raw","ticks_ms":Time.get_ticks_msec(),"event_id":event.get_instance_id(),"event":event.as_text(),"pressed":event.is_pressed(),"matches":matched,"window_focused":DisplayServer.window_is_focused(),"viewport_handled":get_viewport().is_input_handled()}
	if event is InputEventKey:
		record["keycode"]=event.keycode
		record["physical_keycode"]=event.physical_keycode
		record["unicode"]=event.unicode
		record["echo"]=event.echo
	var file: FileAccess=FileAccess.open(debug_log,FileAccess.READ_WRITE)
	file.seek_end();file.store_line(JSON.stringify(record));file.close()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		set_paused(not paused)
	if event.is_action_pressed("reset"):
		vehicle.reset_car()
		camera_snap=true
		hud.show_notice("Vehicle reset")
	if event.is_action_pressed("camera"):
		camera_mode=(camera_mode+1)%3
		camera_snap=true
		hud.show_notice(["Chase camera","Driver camera","Hood camera"][camera_mode])
	if event.is_action_pressed("slow"):
		slow_motion=not slow_motion
		Engine.time_scale=0.125 if slow_motion else 1.0
		hud.slow=slow_motion
	if event.is_action_pressed("fps"):
		hud.fps_visible=not hud.fps_visible
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_RIGHT:
		orbit_drag=event.pressed
	if event is InputEventMouseMotion and orbit_drag and camera_mode==0:
		orbit_yaw-=event.relative.x*0.006
		orbit_pitch=clampf(orbit_pitch+event.relative.y*0.004,-0.12,0.85)
	var debug_log: String=get_meta("input_debug_log","")
	if not debug_log.is_empty() and (event is InputEventKey or event is InputEventMouseButton):
		var file: FileAccess=FileAccess.open(debug_log,FileAccess.READ_WRITE)
		file.seek_end()
		file.store_line(JSON.stringify({"stage":"unhandled","ticks_ms":Time.get_ticks_msec(),"event_id":event.get_instance_id(),"event":event.as_text(),"pressed":event.is_pressed(),"paused":paused,"camera_mode":camera_mode,"slow_motion":slow_motion,"window_focused":DisplayServer.window_is_focused()}))
		file.close()

func _physics_process(dt: float) -> void:
	if paused:
		return
	if not qa or not qa.active:
		var acceleration: float=Input.get_action_strength("accelerate")
		var brake: float=Input.get_action_strength("brake_reverse")
		vehicle.throttle=acceleration
		vehicle.braking=0
		if brake>0:
			if vehicle.forward_speed>0.6:
				vehicle.braking=brake
			else:
				vehicle.throttle=-brake
		elif acceleration>0 and vehicle.forward_speed < -0.6:
			vehicle.throttle=0
			vehicle.braking=acceleration
		vehicle.steering_input=Input.get_action_strength("left")-Input.get_action_strength("right")
		vehicle.handbrake=Input.is_action_pressed("handbrake")
	# The concrete slab spans +/-6000 m; reset before reaching its edge.
	if vehicle.position.y < -20 or absf(vehicle.position.x)>5990 or absf(vehicle.position.z)>5990:
		vehicle.reset_car()
		camera_snap=true
	_skids(dt)

func _process(dt: float) -> void:
	if vehicle==null:
		return
	_camera_update(dt/maxf(Engine.time_scale,0.01))
	hud.cockpit=(camera_mode==1)
	if engine_audio:
		engine_audio.stream_paused=paused
		engine_audio.pitch_scale=clampf(vehicle.rpm/1800.0,0.45,3.5)
		engine_audio.volume_db=-17+absf(vehicle.throttle)*5 if vehicle.engine_health>=0.03 else -65
	if tire_audio:
		tire_audio.stream_paused=paused
		var slip: float=0
		for value: float in vehicle.wheel_slips:
			slip=maxf(slip,value)
		tire_audio.volume_db=linear_to_db(clampf(slip*0.11*minf(vehicle.speed_kph/20,1),0.001,0.16))

func _camera_update(dt: float) -> void:
	_update_scene_reflections()
	var target: Vector3=vehicle.global_position+Vector3.UP*0.78
	var desired: Vector3
	if camera_mode==1:
		desired=vehicle.global_transform*Vector3(-0.405,1.19,0.42)
		target=vehicle.global_transform*Vector3(-0.405,0.10,-15)
		camera.fov=64
	elif camera_mode==2:
		desired=vehicle.global_transform*Vector3(0,1.02,-1.55)
		target=vehicle.global_transform*Vector3(0,0.96,-20)
		camera.fov=69
	else:
		var backward: Vector3=vehicle.global_basis.z
		backward.y=0
		backward=backward.normalized().rotated(Vector3.UP,orbit_yaw)
		desired=target+backward*(5.35+minf(vehicle.speed_kph*0.007,0.75))+Vector3.UP*(1.10+orbit_pitch*1.2)
		camera.fov=lerpf(camera.fov,62+minf(vehicle.speed_kph*0.035,5),minf(dt*3,1))
		var query: PhysicsRayQueryParameters3D=PhysicsRayQueryParameters3D.create(target,desired,1,[vehicle.get_rid()])
		var obstruction: Dictionary=get_world_3d().direct_space_state.intersect_ray(query)
		if not obstruction.is_empty():
			desired=obstruction.position+obstruction.normal*0.25
	if camera_snap or camera_mode>0:
		camera.global_position=desired
		camera_snap=false
	else:
		camera.global_position=camera.global_position.lerp(desired,1-exp(-dt*9))
	if camera.global_position.distance_squared_to(target)>0.001:
		camera.look_at(target,vehicle.global_basis.y if camera_mode>0 else Vector3.UP)
	var mirror_views: Node=get_node_or_null("CockpitMirrorViews")
	if camera_mode==1 and mirror_views==null:
		mirror_views=load("res://mirrors.gd").new()
		mirror_views.name="CockpitMirrorViews"
		add_child(mirror_views)
		mirror_views.setup(self)
	if mirror_views:
		mirror_views.update_views(dt,camera_mode==1)

func set_paused(value: bool) -> void:
	paused=value
	get_tree().paused=value
	pause_panel.visible=value
	hud.visible=not value
	if value:
		var resume_button := pause_panel.find_children("*", "Button", true, false)
		if not resume_button.is_empty():
			resume_button[0].grab_focus()
	vehicle.process_mode=Node.PROCESS_MODE_PAUSABLE

func _pause_menu(layer: CanvasLayer) -> void:
	pause_panel=Control.new()
	pause_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_panel.visible=false
	layer.add_child(pause_panel)
	var shade: ColorRect=ColorRect.new()
	shade.color=Color(0.015,0.025,0.035,0.40)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_panel.add_child(shade)
	var center: CenterContainer=CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_panel.add_child(center)
	var column: VBoxContainer=VBoxContainer.new()
	column.add_theme_constant_override("separation",12)
	column.custom_minimum_size.x=420
	var menu_panel := PanelContainer.new()
	var menu_style := StyleBoxFlat.new()
	menu_style.bg_color = Color(0.09,0.12,0.16,0.96)
	menu_style.set_corner_radius_all(16)
	menu_style.set_border_width_all(1)
	menu_style.border_color = Color("4a5664")
	menu_style.shadow_color = Color(0,0,0,0.28)
	menu_style.shadow_size = 22
	var interface_font := SystemFont.new()
	interface_font.font_names = PackedStringArray(["Helvetica Neue", "Arial"])
	menu_panel.theme = Theme.new()
	menu_panel.theme.default_font = interface_font
	menu_style.content_margin_left = 30
	menu_style.content_margin_right = 30
	menu_style.content_margin_top = 28
	menu_style.content_margin_bottom = 28
	menu_panel.add_theme_stylebox_override("panel", menu_style)
	center.add_child(menu_panel)
	menu_panel.add_child(column)
	var title: Label=Label.new()
	title.text="Vehicle Physics"
	title.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT
	title.add_theme_font_size_override("font_size",34)
	title.add_theme_color_override("font_color",Color("f1f0e8"))
	column.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Paused"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.add_theme_color_override("font_color", Color("aaafa9"))
	column.add_child(subtitle)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 15
	column.add_child(spacer)
	for label: String in ["Resume","Reset vehicle","Quit"]:
		var button: Button=Button.new()
		button.text=label
		button.custom_minimum_size.y=48
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color("3476ae") if label == "Resume" else Color("303a45")
		normal.set_corner_radius_all(8)
		normal.content_margin_left = 18
		normal.content_margin_right = 18
		var hover := normal.duplicate() as StyleBoxFlat
		hover.bg_color = Color("4588c1") if label == "Resume" else Color("414f5f")
		var focus := StyleBoxFlat.new()
		focus.bg_color = Color.TRANSPARENT
		focus.border_color = Color("99c9f4")
		focus.set_border_width_all(2)
		button.add_theme_stylebox_override("normal", normal)
		button.add_theme_stylebox_override("hover", hover)
		button.add_theme_stylebox_override("focus", focus)
		button.add_theme_stylebox_override("pressed", hover)
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_color_override("font_color", Color("f1f0e8"))
		column.add_child(button)
		button.pressed.connect(func():
			if label=="Quit":
				get_tree().quit()
			elif label=="Reset vehicle":
				vehicle.reset_car()
				camera_snap=true
				set_paused(false)
			else:
				set_paused(false))

	var controls := GridContainer.new()
	controls.columns = 2
	controls.add_theme_constant_override("h_separation", 38)
	controls.add_theme_constant_override("v_separation", 10)
	column.add_child(controls)
	for pair in [["WASD / arrows", "Drive / reverse"], ["Space", "Handbrake"], ["Tab / C", "Camera"], ["R", "Reset vehicle"], ["J", "Slow motion"], ["Esc", "Resume"]]:
		for i in range(2):
			var text := Label.new()
			text.text = pair[i]
			text.add_theme_font_size_override("font_size", 15)
			text.add_theme_color_override("font_color", Color("d7e0e9") if i == 0 else Color("a8b6c4"))
			controls.add_child(text)

func _skids(dt: float) -> void:
	skid_timer+=dt
	if skid_timer<0.045:
		return
	skid_timer=0
	for i: int in range(4):
		var locked_rear: bool=vehicle.handbrake and i>=2
		if vehicle.wheel_loads[i]<100 or vehicle.speed_kph<8 or (vehicle.wheel_slips[i]<0.2 and not locked_rear and vehicle.braking<0.7):
			skid_previous[i]=Vector3.ZERO
			skid_previous_side[i]=Vector3.ZERO
			continue
		var normal: Vector3=vehicle.wheel_support_normals[i]
		# Painted road overlays reach 36 mm above the physical slab.
		var p: Vector3=vehicle.wheel_contacts[i]+normal*0.040
		if skid_previous[i]!=Vector3.ZERO:
			var length: float=p.distance_to(skid_previous[i])
			if length>0.035 and length<4:
				var side: Vector3=(p-skid_previous[i]).cross(normal).normalized()*0.09
				if skid_previous_side[i]==Vector3.ZERO: skid_previous_side[i]=side
				var arrays: Array=[]
				arrays.resize(Mesh.ARRAY_MAX)
				# Adjacent quads share their complete edge, including through
				# a turn; intersecting rectangles left dark triangular joints.
				arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([skid_previous[i]-skid_previous_side[i],skid_previous[i]+skid_previous_side[i],p+side,p-side])
				arrays[Mesh.ARRAY_NORMAL]=PackedVector3Array([normal,normal,normal,normal])
				arrays[Mesh.ARRAY_TEX_UV]=PackedVector2Array([Vector2(0,0),Vector2(1,0),Vector2(1,1),Vector2(0,1)])
				arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,2,1,0,3,2])
				var mesh:=ArrayMesh.new()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
				var stripe: MeshInstance3D=MeshInstance3D.new()
				stripe.mesh=mesh
				stripe.material_override=_skid_surface()
				stripe.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(stripe)
				skid_previous_side[i]=side
				skid_nodes.append(stripe)
				if skid_nodes.size()>360:
					skid_nodes.pop_front().queue_free()
			else:
				skid_previous_side[i]=Vector3.ZERO
		skid_previous[i]=p

func _skid_surface() -> ShaderMaterial:
	if skid_material: return skid_material
	var shader:=Shader.new()
	shader.code="""shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;
varying vec3 mark_position;
void vertex() { mark_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment() {
    float edge=smoothstep(0.01,0.11,UV.x)*smoothstep(0.01,0.11,1.0-UV.x);
    vec2 grain_position=mark_position.xz*140.0;
    float grain=fract(sin(dot(floor(grain_position),vec2(12.9898,78.233)))*43758.5453);
    float footprint=max(length(dFdx(grain_position)),length(dFdy(grain_position)));
    grain=mix(grain,0.5,smoothstep(0.3,1.0,footprint));
    float groove=1.0-0.18*(1.0-smoothstep(0.012,0.030,abs(UV.x-0.30)))-0.18*(1.0-smoothstep(0.012,0.030,abs(UV.x-0.70)));
    ALBEDO=vec3(0.025,0.023,0.021);
    ALPHA=edge*groove*mix(0.31,0.43,grain);
}
"""
	skid_material=ShaderMaterial.new()
	skid_material.shader=shader
	return skid_material

func _setup_audio() -> void:
	if DisplayServer.get_name()=="headless":
		return
	for entry: Array in [["engine",true],["tire",true],["crash",false]]:
		var path: String="res://assets/audio/%s.wav"%entry[0]
		if not ResourceLoader.exists(path):
			continue
		var player: AudioStreamPlayer=AudioStreamPlayer.new()
		player.stream=load(path)
		player.volume_db=-25
		add_child(player)
		if entry[1]:
			player.stream.loop_begin=0
			player.stream.loop_end=roundi(player.stream.get_length()*player.stream.mix_rate)
			player.stream.loop_mode=AudioStreamWAV.LOOP_FORWARD
			player.play()
		if entry[0]=="engine": engine_audio=player
		if entry[0]=="tire": tire_audio=player
		if entry[0]=="crash": crash_audio=player

func _impact_sound(_p: Vector3,_direction: Vector3,severity: float) -> void:
	if crash_audio:
		crash_audio.volume_db=clampf(-17+severity*0.5,-17,-3)
		crash_audio.pitch_scale=randf_range(0.82,1.13)
		crash_audio.play()
