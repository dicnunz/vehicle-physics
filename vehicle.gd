extends RigidBody3D
class_name SimVehicle


signal collided(local_point: Vector3, direction: Vector3, severity: float)

const RADIUS: float = 0.335
const TIRE_WIDTH: float = 0.215
const REST: float = 0.47
const MAX_TRAVEL: float = REST+0.16
const TIRE_SKIN: float = 0.003
const MOUNTS: Array[Vector3] = [Vector3(-0.81,0.84,-1.34),Vector3(0.81,0.84,-1.34),Vector3(-0.81,0.84,1.34),Vector3(0.81,0.84,1.34)]
const GEARS: Array[float] = [3.42,2.14,1.42,1.0,0.81]
var throttle: float = 0.0
var braking: float = 0.0
var steering_input: float = 0.0
var handbrake: bool = false
var steering_angle: float = 0.0
var gear: int = 1
var rpm: float = 850.0
var speed_kph: float = 0.0
var forward_speed: float = 0.0
var grounded: int = 0
var wheel_lengths: Array[float] = [REST,REST,REST,REST]
var wheel_supported: Array[bool]=[false,false,false,false]
var wheel_spins: Array[float] = [0.0,0.0,0.0,0.0]
var wheel_angular_velocity: Array[float] = [0.0,0.0,0.0,0.0]
var wheel_slips: Array[float] = [0.0,0.0,0.0,0.0]
var wheel_loads: Array[float] = [0.0,0.0,0.0,0.0]
var wheel_contacts: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var wheel_damage: Array[float] = [0.0,0.0,0.0,0.0]
var engine_health: float = 1.0
var damage: float = 0.0
var peak_impact: float = 0.0
var shift_timer: float = 0.0
var impact_cooldown: float = 0.0
var simulation_time: float = 0.0
var visual: Node3D
var wheels: Array[Node3D] = []
var wheel_origins: Array[Transform3D] = []
var deformer: Node
var previous_velocity: Vector3 = Vector3.ZERO
var reset_pending: bool = false
var reset_transform: Transform3D
var reset_velocity: Vector3 = Vector3.ZERO
var _last_contact: Vector3 = Vector3.ZERO
var _skid_last: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var impact_count: int = 0
var deformable_colliders: Array = []
var wheel_offsets: Array[Vector3]=[Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var wheel_alignment: Array[Basis]=[Basis.IDENTITY,Basis.IDENTITY,Basis.IDENTITY,Basis.IDENTITY]
var wheel_detached: Array[bool]=[false,false,false,false]
var debris: Array[Node3D]=[]
var transmission_reverse: bool=false
var instruments: Array[Node3D]=[]
var wheel_support_normals: Array[Vector3]=[Vector3.UP,Vector3.UP,Vector3.UP,Vector3.UP]
var wheel_obstacle_forces: Array[Vector3]=[Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var wheel_obstacle_contacts: Array[int]=[0,0,0,0]
var _support_shapes: Array[CylinderShape3D]=[]
var _obstacle_shapes: Array[CylinderShape3D]=[]
var _tire_linear_correction: Vector3=Vector3.ZERO
var _tire_angular_correction: Vector3=Vector3.ZERO
var lamp_materials: Array[Dictionary]=[]
var lamps_ready: bool=false
var applied_structure_force: Vector3=Vector3.ZERO
var applied_structure_torque: Vector3=Vector3.ZERO

func _ready() -> void:
	mass = 1360.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0,0.54,-0.08)
	linear_damp = 0.012
	angular_damp = 0.18
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	continuous_cd = true
	can_sleep = false
	custom_integrator=true
	contact_monitor = true
	max_contacts_reported = 16
	var material: PhysicsMaterial = PhysicsMaterial.new()
	material.friction = 0.45
	material.bounce = 0.025
	physics_material_override = material
	_add_collider(Vector3(1.68,0.49,1.26),Vector3(0,0.68,-1.52))
	_add_collider(Vector3(1.63,0.47,1.13),Vector3(0,0.68,1.57))
	_add_collider(Vector3(1.62,0.63,1.92),Vector3(0,0.82,0.02))
	_add_collider(Vector3(1.40,0.24,1.67),Vector3(0,1.23,0.10))
	load_visual()
	deformer = load("res://deformer.gd").new()
	add_child(deformer)
	deformer.setup(visual)
	deformer.nodal_collision_enabled=true
	deformer.enable_full_body_contacts()
	center_of_mass=deformer.center
	inertia=deformer.inertia
	deformable_colliders[0].node.disabled=true
	deformable_colliders[1].node.disabled=true
	collided.connect(_on_impact)
	for i: int in range(4):
		var support_shape: CylinderShape3D=CylinderShape3D.new()
		support_shape.radius=RADIUS
		support_shape.height=TIRE_WIDTH
		_support_shapes.append(support_shape)
		var obstacle_shape: CylinderShape3D=CylinderShape3D.new()
		obstacle_shape.radius=RADIUS-0.004
		obstacle_shape.height=TIRE_WIDTH-0.002
		_obstacle_shapes.append(obstacle_shape)

func _add_collider(size: Vector3, at: Vector3) -> void:
	var collision: CollisionShape3D = CollisionShape3D.new()
	var hull: ConvexPolygonShape3D = ConvexPolygonShape3D.new()
	var points: PackedVector3Array=PackedVector3Array()
	for x: int in [-1,1]:
		for y: int in [-1,1]:
			for z: int in [-1,1]:
				points.append(at+Vector3(x,y,z)*size*0.5)
	hull.points=points
	collision.shape = hull
	add_child(collision)
	deformable_colliders.append({"node":collision,"points":points})

func update_collision_cage() -> void:
	if not deformer.full_body_contacts_enabled:
		for shape: Dictionary in deformable_colliders:
			var points: PackedVector3Array=shape.points.duplicate()
			for i: int in range(points.size()): points[i]+=deformer.displacement_at(points[i])
			var hull: ConvexPolygonShape3D=ConvexPolygonShape3D.new()
			hull.points=points
			shape.node.set_deferred("shape",hull)
	update_attachment_poses()

func update_attachment_poses() -> void:
	for i: int in range(4):
		wheel_offsets[i]=deformer.displacement_at(MOUNTS[i])
		wheel_alignment[i]=deformer.rotation_at(MOUNTS[i],wheel_alignment[i])
		var attachment: Vector3=deformer.attachment_strain(MOUNTS[i]) if deformer.has_method("attachment_strain") else wheel_offsets[i]
		var strain: float=maxf(0.0,attachment.length()-0.025)
		wheel_damage[i]=maxf(wheel_damage[i],clampf(strain/0.445,0,1))
		if wheel_damage[i]>0.96 and not wheel_detached[i]:
			_detach_wheel.call_deferred(i)
	var engine_displacement: Vector3=deformer.attachment_strain(Vector3(0,0.66,-1.55)) if deformer.has_method("attachment_strain") else deformer.displacement_at(Vector3(0,0.66,-1.55))
	var engine_crush: float=maxf(0.0,engine_displacement.length()-0.025)
	engine_health=minf(engine_health,clampf(1.0-pow(engine_crush/0.53,1.65),0.0,1.0))

func _tire_query(shape: Shape3D, at: Transform3D, motion: Vector3=Vector3.ZERO) -> PhysicsShapeQueryParameters3D:
	var query: PhysicsShapeQueryParameters3D=PhysicsShapeQueryParameters3D.new()
	query.shape=shape
	query.transform=at
	query.motion=motion
	query.collision_mask=1
	var exclusions: Array[RID]=[get_rid()]
	for part: Node3D in debris:
		if is_instance_valid(part) and part is CollisionObject3D: exclusions.append(part.get_rid())
	query.exclude=exclusions
	return query

func _tire_support(space: PhysicsDirectSpaceState3D, index: int, mount: Vector3, up: Vector3, tire_basis: Basis, radius: float) -> Dictionary:
	var shape: CylinderShape3D=_support_shapes[index]
	shape.radius=radius
	shape.height=TIRE_WIDTH*(radius/RADIUS)
	var motion: Vector3=-up*MAX_TRAVEL
	var query: PhysicsShapeQueryParameters3D=_tire_query(shape,Transform3D(tire_basis,mount),motion)
	var fraction: PackedFloat32Array=space.cast_motion(query)
	if fraction.size()<2 or fraction[0]>=1.0:
		return {}
	var length: float=fraction[0]*MAX_TRAVEL
	if length>REST+0.15:
		return {}
	query.motion=Vector3.ZERO
	# cast_motion supplies a TOI, not a contact manifold. A tiny overlap at the
	# unsafe transform retrieves the actual curb/edge normal and world point.
	query.transform.origin=mount-up*(fraction[1]*MAX_TRAVEL+TIRE_SKIN)
	var info: Dictionary=space.get_rest_info(query)
	if info.is_empty():
		query.margin=TIRE_SKIN*2.0
		info=space.get_rest_info(query)
	if info.is_empty() or Vector3(info.normal).dot(up)<0.25:
		return {}
	# Refine the quantized sweep fraction against its contact tangent plane.
	# The cylinder support function includes both radial extent and tire width.
	var normal: Vector3=info.normal
	var axial: float=clampf(absf(normal.dot(tire_basis.y)),0.0,1.0)
	var extent: float=radius*sqrt(maxf(0.0,1.0-axial*axial))+shape.height*0.5*axial
	var refined: float=(normal.dot(mount-Vector3(info.point))-extent)/normal.dot(up)
	length=clampf(refined,maxf(0.0,length-0.008),minf(MAX_TRAVEL,length+0.008))
	info["length"]=length
	info["position"]=info.point
	info["collider"]=instance_from_id(info.collider_id)
	return info

func _tire_obstacle_force(state: PhysicsDirectBodyState3D, index: int, center: Vector3, tire_basis: Basis, radius: float, up: Vector3) -> Vector3:
	var shape: CylinderShape3D=_obstacle_shapes[index]
	shape.radius=radius-0.004
	shape.height=TIRE_WIDTH*(radius/RADIUS)-0.002
	var space: PhysicsDirectSpaceState3D=state.get_space_state()
	var query: PhysicsShapeQueryParameters3D=_tire_query(shape,Transform3D(tire_basis,center))
	var info: Dictionary=space.get_rest_info(query)
	var penetration: float=0.0
	if not info.is_empty() and absf(Vector3(info.normal).dot(up))<0.35:
		var points: PackedVector3Array=PackedVector3Array(space.collide_shape(query,4))
		for p: int in range(0,points.size()-1,2):
			penetration=maxf(penetration,absf((points[p]-points[p+1]).dot(info.normal)))
	else:
		var from_com: Vector3=center-state.transform.origin-state.transform.basis*center_of_mass
		var velocity: Vector3=state.linear_velocity+state.angular_velocity.cross(from_com)
		var travel: Vector3=(velocity-up*velocity.dot(up))*state.step
		if travel.length_squared()<0.00000001:
			return Vector3.ZERO
		query.motion=travel+travel.normalized()*TIRE_SKIN
		var fraction: PackedFloat32Array=space.cast_motion(query)
		if fraction.size()<2 or fraction[0]>=1.0:
			return Vector3.ZERO
		query.transform.origin=center+query.motion*fraction[1]+travel.normalized()*TIRE_SKIN
		query.motion=Vector3.ZERO
		info=space.get_rest_info(query)
	if info.is_empty():
		return Vector3.ZERO
	var normal: Vector3=info.normal
	# Upward-facing tread contacts are already carried by the suspension sweep.
	# This second envelope handles a tire sidewall or a near-vertical obstruction.
	if absf(normal.dot(up))>=0.35:
		return Vector3.ZERO
	var contact: Vector3=info.point
	var r: Vector3=contact-state.transform.origin-state.transform.basis*center_of_mass
	var collider_velocity: Vector3=info.get("linear_velocity",Vector3.ZERO)
	var contact_velocity: Vector3=state.linear_velocity+_tire_linear_correction+(state.angular_velocity+_tire_angular_correction).cross(r)-collider_velocity
	var inverse_effective_mass: float=state.inverse_mass+normal.dot((state.inverse_inertia_tensor*r.cross(normal)).cross(r))
	var correction_speed: float=minf(penetration*0.20/state.step,1.5)
	var impulse: Vector3=normal*maxf(0.0,-contact_velocity.dot(normal)+correction_speed)/maxf(inverse_effective_mass,0.000001)
	if impulse.length_squared()<0.000001:
		return Vector3.ZERO
	var force: Vector3=impulse/state.step
	_apply_structure_force(state,force,contact-state.transform.origin)
	# Sequential contact prediction shares momentum between tires without
	# changing the body's position or directly assigning its velocity.
	_tire_linear_correction+=impulse*state.inverse_mass
	_tire_angular_correction+=state.inverse_inertia_tensor*r.cross(impulse)
	wheel_obstacle_contacts[index]+=1
	return force

func _emit_body_contact_patches(state: PhysicsDirectBodyState3D) -> void:
	if state.get_contact_count()==0 or impact_cooldown>0:
		return
	var samples: Array[Dictionary]=[]
	var inverse: Transform3D=state.transform.affine_inverse()
	for contact: int in range(state.get_contact_count()):
		var impulse: float=state.get_contact_impulse(contact).length()
		# Jolt reports both these contact values in world coordinates.
		var point: Vector3=inverse*state.get_contact_local_position(contact)
		var normal: Vector3=state.transform.basis.inverse()*state.get_contact_local_normal(contact)
		samples.append({"point":point,"normal":normal,"impulse":impulse})
	var patches: Array[Dictionary]=_cluster_body_contact_samples(samples)
	var total_impulse: float=0.0
	for patch: Dictionary in patches:
		total_impulse+=patch.impulse
	if total_impulse/mass<=2.1:
		return
	for patch: Dictionary in patches:
		var severity: float=patch.impulse/mass
		if severity>0.35:
			call_deferred("emit_signal","collided",patch.point,patch.normal,severity)
	impact_cooldown=0.12

func _cluster_body_contact_samples(samples: Array[Dictionary]) -> Array[Dictionary]:
	var patches: Array[Dictionary]=[]
	for sample: Dictionary in samples:
		var impulse: float=sample.impulse
		if impulse<0.01:
			continue
		var point: Vector3=sample.point
		var normal: Vector3=sample.normal
		var selected: int=-1
		var nearest: int=-1
		var best: float=INF
		for p: int in range(patches.size()):
			var center: Vector3=patches[p].point/patches[p].impulse
			var distance: float=point.distance_squared_to(center)
			if distance<best:
				best=distance
				nearest=p
			if distance<0.65*0.65 and normal.dot(Vector3(patches[p].normal).normalized())>0.60:
				selected=p
				break
		if selected<0 and patches.size()<4:
			patches.append({"point":Vector3.ZERO,"normal":Vector3.ZERO,"impulse":0.0})
			selected=patches.size()-1
		elif selected<0:
			selected=nearest
		patches[selected].point+=point*impulse
		patches[selected].normal+=normal*impulse
		patches[selected].impulse+=impulse
	for patch: Dictionary in patches:
		patch.point/=patch.impulse
		patch.normal=Vector3(patch.normal).normalized()
	return patches

func load_visual() -> void:
	if ResourceLoader.exists("res://assets/vehicle/sedan.glb"):
		visual = load("res://assets/vehicle/sedan.glb").instantiate()
	else:
		visual = Node3D.new()
		var body: MeshInstance3D = MeshInstance3D.new()
		var mesh: BoxMesh = BoxMesh.new()
		mesh.size = Vector3(1.8,0.65,4.5)
		body.mesh = mesh
		body.position.y = 0.72
		var paint: StandardMaterial3D = StandardMaterial3D.new()
		paint.albedo_color = Color(0.04,0.19,0.38)
		paint.metallic = 0.65
		paint.roughness = 0.26
		body.material_override = paint
		visual.add_child(body)
	add_child(visual)
	for label: String in ["SteeringWheel","Needle_Speed","Needle_RPM"]:
		instruments.append(visual.find_child(label,true,false))
	for label: String in ["Wheel_FL","Wheel_FR","Wheel_RL","Wheel_RR"]:
		var wheel: Node3D = visual.find_child(label,true,false)
		if wheel == null:
			wheel = Node3D.new()
			wheel.name = label
			visual.add_child(wheel)
			wheel.position = MOUNTS[wheels.size()] - Vector3(0,0.505,0)
			var tire: MeshInstance3D = MeshInstance3D.new()
			var cylinder: CylinderMesh = CylinderMesh.new()
			cylinder.top_radius = RADIUS
			cylinder.bottom_radius = RADIUS
			cylinder.height = 0.22
			tire.mesh = cylinder
			tire.rotation.z = PI/2
			var rubber: StandardMaterial3D = StandardMaterial3D.new()
			rubber.albedo_color = Color(0.025,0.026,0.029)
			tire.material_override = rubber
			wheel.add_child(tire)
		wheels.append(wheel)
		wheel_origins.append(wheel.transform)

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var dt: float = state.step
	applied_structure_force=Vector3.ZERO
	applied_structure_torque=Vector3.ZERO
	simulation_time += dt
	if reset_pending:
		state.transform = reset_transform
		state.linear_velocity = reset_velocity
		state.angular_velocity = Vector3.ZERO
		previous_velocity = reset_velocity
		reset_pending = false
		return
	var basis: Basis = state.transform.basis
	var forward: Vector3 = -basis.z
	forward_speed = state.linear_velocity.dot(forward)
	speed_kph = Vector2(state.linear_velocity.x,state.linear_velocity.z).length()*3.6
	var desired: float = steering_input * lerpf(0.52,0.15,clampf(absf(forward_speed)/46.0,0,1))
	steering_angle = move_toward(steering_angle,desired,dt*1.35)
	shift_timer = maxf(0,shift_timer-dt)
	impact_cooldown = maxf(0,impact_cooldown-dt)
	if throttle < -0.05 and forward_speed < 0.6:
		transmission_reverse=true
	elif throttle>0.05 and forward_speed>-0.6:
		transmission_reverse=false
	var reverse: bool = transmission_reverse
	gear = -1 if reverse else maxi(1,gear)
	var ratio: float = 3.18 if reverse else GEARS[gear-1]
	var driven_rpm: float = (absf(wheel_angular_velocity[2])+absf(wheel_angular_velocity[3]))*0.5*ratio*3.73*9.5493
	var unloaded: bool=wheel_loads[2]+wheel_loads[3]<150
	var target_rpm: float = 850+absf(throttle)*5500 if unloaded else maxf(850.0+absf(throttle)*950, driven_rpm + absf(throttle)*380.0)
	if engine_health<0.03:
		target_rpm=0
	rpm = lerpf(rpm,minf(target_rpm,6400),minf(dt*12,1))
	if not reverse and shift_timer <= 0:
		if rpm > 5350 and gear < GEARS.size():
			gear += 1
			shift_timer = 0.24
		elif rpm < 1650 and gear > 1:
			gear -= 1
			shift_timer = 0.18
	var torque: float = 224.0 * (0.68+0.32*sin(clampf((rpm-850.0)/5600.0,0,1)*PI))
	var drive: float = throttle * torque * ratio * 3.73 * 0.9 / RADIUS * engine_health
	drive*=clampf((6500.0-driven_rpm)/500.0,0,1)
	if shift_timer > 0:
		drive *= 0.15
	var locked_brake_contacts: int=0
	for i: int in range(4):
		if not wheel_detached[i] and wheel_loads[i]>100.0 and (braking>0.001 or (handbrake and i>=2)):
			locked_brake_contacts+=1
	_tire_linear_correction=Vector3.ZERO
	_tire_angular_correction=Vector3.ZERO
	grounded = 0
	for i: int in range(4):
		wheel_obstacle_forces[i]=Vector3.ZERO
		if wheel_detached[i]:
			wheel_loads[i]=0
			continue
		var tire_radius: float=RADIUS*(1-wheel_damage[i]*0.13)
		var local_mount: Vector3 = MOUNTS[i] + wheel_offsets[i]
		var mount: Vector3 = state.transform * local_mount
		var attachment_basis: Basis=basis*wheel_alignment[i]*Basis(Vector3.UP,steering_angle if i<2 else 0.0)
		var wheel_forward: Vector3=-attachment_basis.z
		var tire_basis: Basis=Basis(wheel_forward,attachment_basis.x,-attachment_basis.y)
		var hit: Dictionary = _tire_support(state.get_space_state(),i,mount,basis.y,tire_basis,tire_radius)
		wheel_loads[i] = 0.0
		wheel_slips[i] = 0.0
		if hit.is_empty():
			wheel_supported[i]=false
			wheel_lengths[i] = move_toward(wheel_lengths[i],REST+0.16,dt*1.5)
			wheel_obstacle_forces[i]=_tire_obstacle_force(state,i,mount-basis.y*wheel_lengths[i],tire_basis,tire_radius,basis.y)
			if deformer and deformer.has_method("add_load") and wheel_obstacle_forces[i].length_squared()>0:
				deformer.add_load(MOUNTS[i],basis.inverse()*wheel_obstacle_forces[i])
			if i>=2:
				wheel_angular_velocity[i]+=drive*0.5*RADIUS/1.8*dt
			wheel_angular_velocity[i]*=exp(-dt*0.12)
			if braking>0 or (handbrake and i>=2):
				wheel_angular_velocity[i]=move_toward(wheel_angular_velocity[i],0,dt*900)
			wheel_spins[i] += wheel_angular_velocity[i]*dt
			continue
		var contact: Vector3 = hit.position
		var normal: Vector3 = hit.normal
		var length: float = hit.length
		grounded += 1
		wheel_contacts[i] = contact
		wheel_support_normals[i]=normal
		var suspension_speed: float=clampf((length-wheel_lengths[i])/dt,-8.0,8.0)
		if not wheel_supported[i]:
			var mount_velocity: Vector3=state.linear_velocity+state.angular_velocity.cross(mount-state.transform*center_of_mass)-Vector3(hit.get("linear_velocity",Vector3.ZERO))
			suspension_speed=clampf(mount_velocity.dot(normal)/maxf(normal.dot(basis.y),0.3),-8.0,8.0)
		wheel_supported[i]=true
		wheel_lengths[i] = clampf(length,0.08,REST+0.16)
		wheel_obstacle_forces[i]=_tire_obstacle_force(state,i,mount-basis.y*wheel_lengths[i],tire_basis,tire_radius,basis.y)
		var offset: Vector3 = contact-state.transform.origin
		var velocity: Vector3 = state.linear_velocity + state.angular_velocity.cross(offset-basis*center_of_mass)-Vector3(hit.get("linear_velocity",Vector3.ZERO))
		var compression: float = REST-length
		var spring: float = maxf(compression,0)*39000.0*(1-wheel_damage[i]*0.40)
		if compression > 0.27:
			spring += (compression-0.27)*160000.0
		var vertical_speed: float = suspension_speed
		var load_force: float = clampf(spring-vertical_speed*(4300.0 if vertical_speed<0 else 3400.0),0.0,26000.0)
		var normal_load: float=load_force/maxf(normal.dot(basis.y),0.30)
		var support_force: Vector3=normal*normal_load
		wheel_loads[i] = normal_load
		_apply_structure_force(state,support_force,offset)
		wheel_forward = (wheel_forward-normal*wheel_forward.dot(normal)).normalized()
		var wheel_right: Vector3 = wheel_forward.cross(normal).normalized()
		var vl: float = velocity.dot(wheel_forward)
		var vs: float = velocity.dot(wheel_right)
		var mu: float = 1.04 - wheel_damage[i]*0.3
		if hit.collider and hit.collider.has_meta("surface") and hit.collider.get_meta("surface") == "gravel":
			mu = 0.64
		var available: float = normal_load*mu
		var brake_force: float = braking*11500.0*(0.32 if i<2 else 0.18)
		if handbrake and i>=2:
			brake_force += 5800.0
		var quarter_mass: float=mass*0.25
		var gravity_along: float=(state.total_gravity+support_force/quarter_mass).dot(wheel_forward)
		var predicted_v: float=vl+gravity_along*dt
		var wheel_torque: float=drive*0.5*tire_radius if i>=2 else 0.0
		var resistance_torque: float=(brake_force+load_force*0.012)*tire_radius
		var unbraked_omega: float=wheel_angular_velocity[i]+wheel_torque/1.8*dt
		var free_omega: float=move_toward(unbraked_omega,0,resistance_torque/1.8*dt)
		# Longitudinal friction exchanges momentum with a rotating wheel. The
		# friction circle bounds the contact impulse, permitting real wheelspin.
		var longitudinal_slip: float=free_omega*tire_radius-predicted_v
		var long_force: float=longitudinal_slip/(dt*(1.0/quarter_mass+tire_radius*tire_radius/1.8))
		# Static brake torque balances the contact reaction while the wheel is
		# locked. Rolling resistance uses the same dissipative torque law.
		# An axle-only handbrake must react the whole body's downhill momentum.
		# Share that static constraint between the braked contacts, while retaining
		# quarter-mass rotating-wheel coupling and per-tire friction limits.
		var locked_mass: float=mass/float(maxi(locked_brake_contacts,1)) if brake_force>0.01 else quarter_mass
		var locked_force: float=clampf(-predicted_v*locked_mass/dt,-available,available)
		var required_torque: float=unbraked_omega*1.8/dt-locked_force*tire_radius
		var locked: bool=absf(required_torque)<=resistance_torque
		if locked:
			long_force=locked_force
		var predicted_side: float=vs+(state.total_gravity+support_force/quarter_mass).dot(wheel_right)*dt
		var lateral_force: float = -predicted_side*minf(8000.0,62000.0/(absf(vl)+3.0))
		if handbrake and i>=2:
			lateral_force *= 0.42
		var total: float = Vector2(long_force,lateral_force).length()
		var slip: float = maxf(0,total/maxf(available,10)-1)
		wheel_slips[i] = minf(2.0,slip+absf(vs)*0.035)
		if total > available:
			var sliding: float = 0.84 if slip>0.35 else 1.0
			long_force *= available/maxf(total,1)*sliding
			lateral_force *= available/maxf(total,1)*sliding
		var tire_force: Vector3=wheel_forward*long_force+wheel_right*lateral_force
		_apply_structure_force(state,tire_force,offset)
		if deformer and deformer.has_method("add_load"):
			deformer.add_load(MOUNTS[i],basis.inverse()*(support_force+tire_force+wheel_obstacle_forces[i]))
		wheel_angular_velocity[i]=0.0 if locked else free_omega-long_force*tire_radius/1.8*dt
		wheel_spins[i] += wheel_angular_velocity[i]*dt
	# Air drag acts at the center of mass; there is no artificial ground pinning.
	var air: Vector3 = -state.linear_velocity*state.linear_velocity.length()*0.41
	_apply_structure_force(state,air,state.transform.basis*center_of_mass)
	_emit_body_contact_patches(state)
	previous_velocity=state.linear_velocity
	deformer.integrate_contacts(state,dt)

func _process(_dt: float) -> void:
	if not lamps_ready and simulation_time>0.1:
		_collect_lamps(visual)
		lamps_ready=true
	for lamp: Dictionary in lamp_materials:
		lamp.material.emission_energy_multiplier=(1.8 if braking>0.05 else 0.0) if lamp.red else (0.9 if transmission_reverse else 0.0)
	if instruments.size()==3:
		if instruments[0]: instruments[0].basis=Basis(Vector3(0,0.309017,0.951057),steering_angle*12.0)
		if instruments[1]: instruments[1].rotation.z=deg_to_rad(-270.0)*clampf(speed_kph/240.0,0,1)
		if instruments[2]: instruments[2].rotation.z=deg_to_rad(-270.0)*clampf(rpm/8000.0,0,1)
	for i: int in range(wheels.size()):
		var wheel: Node3D = wheels[i]
		wheel.visible=not wheel_detached[i]
		if wheel_detached[i]:
			continue
		var initial: Transform3D = wheel_origins[i]
		wheel.transform = initial
		wheel.position = Vector3(MOUNTS[i].x,MOUNTS[i].y-wheel_lengths[i],MOUNTS[i].z)+wheel_offsets[i]
		wheel.basis=wheel_alignment[i]*Basis(Vector3.UP,steering_angle if i<2 else 0.0)*Basis(Vector3.RIGHT,-wheel_spins[i])
		wheel.scale=Vector3.ONE*(1-wheel_damage[i]*0.13)

func _collect_lamps(node: Node) -> void:
	if node is MeshInstance3D and String(node.name).begins_with("Taillights"):
		for surface: int in range(node.mesh.get_surface_count()):
			var source: Material=node.get_active_material(surface)
			if not source is StandardMaterial3D: continue
			var label: String=source.resource_name.to_lower()
			if "red tail light" not in label and "reverse light" not in label: continue
			var material: StandardMaterial3D=source.duplicate()
			var red: bool="red tail light" in label
			material.emission_enabled=true
			material.emission=Color(1,0.018,0.004) if red else Color(0.88,0.94,1)
			material.emission_energy_multiplier=0
			node.set_surface_override_material(surface,material)
			lamp_materials.append({"material":material,"red":red})
	for child: Node in node.get_children(): _collect_lamps(child)

func _detach_wheel(index: int) -> void:
	if wheel_detached[index]:
		return
	wheel_detached[index]=true
	var loose: RigidBody3D=RigidBody3D.new()
	loose.mass=22
	loose.continuous_cd=true
	var mesh: Node3D=wheels[index].duplicate()
	mesh.transform=Transform3D.IDENTITY
	loose.add_child(mesh)
	var collision: CollisionShape3D=CollisionShape3D.new()
	var shape: CylinderShape3D=CylinderShape3D.new()
	shape.radius=RADIUS
	shape.height=0.21
	collision.shape=shape
	collision.rotation.z=PI/2
	loose.add_child(collision)
	get_parent().add_child(loose)
	loose.global_transform=wheels[index].global_transform
	loose.linear_velocity=linear_velocity+global_basis.x*(2 if index%2 else -2)
	loose.angular_velocity=global_basis.x*(-forward_speed/RADIUS)
	loose.add_collision_exception_with(self)
	debris.append(loose)

func _on_impact(point: Vector3, direction: Vector3, severity: float) -> void:
	peak_impact=maxf(peak_impact,severity)
	impact_count+=1
	var strength: float = clampf((severity-1.8)*0.055,0.03,1.15)
	damage=clampf(damage+strength*0.24,0,1)
	if point.z < -0.7:
		engine_health=clampf(engine_health-strength*0.32,0.08,1)
	for i: int in range(4):
		var distance: float = point.distance_to(MOUNTS[i])
		if distance < 1.2:
			wheel_damage[i]=minf(1,wheel_damage[i]+strength*(1-distance/1.2))
	deformer.impact(point,direction,strength)

func reset_car(at: Vector3=Vector3(0,0.12,15),heading: float=0,velocity: Vector3=Vector3.ZERO) -> void:
	reset_transform=Transform3D(Basis(Vector3.UP,heading),at)
	reset_velocity=velocity
	reset_pending=true
	damage=0
	engine_health=1
	peak_impact=0
	impact_count=0
	gear=1
	transmission_reverse=false
	rpm=850
	steering_angle=0
	throttle=0
	braking=0
	wheel_damage=[0.0,0.0,0.0,0.0]
	wheel_supported=[false,false,false,false]
	wheel_offsets=[Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
	wheel_alignment=[Basis.IDENTITY,Basis.IDENTITY,Basis.IDENTITY,Basis.IDENTITY]
	wheel_detached=[false,false,false,false]
	for part: Node3D in debris:
		if is_instance_valid(part):
			part.queue_free()
	debris.clear()
	wheel_spins=[0.0,0.0,0.0,0.0]
	wheel_angular_velocity=[0.0,0.0,0.0,0.0]
	wheel_obstacle_contacts=[0,0,0,0]
	wheel_obstacle_forces=[Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
	if deformer:
		deformer.reset_mesh()
		update_collision_cage()

func telemetry() -> Dictionary:
	return {"position":[position.x,position.y,position.z],"speed_kph":speed_kph,"forward_speed":forward_speed,"rpm":rpm,"gear":gear,"grounded":grounded,"damage":damage,"engine_health":engine_health,"wheel_damage":wheel_damage.duplicate(),"suspension":wheel_lengths.duplicate(),"peak_impact":peak_impact,"impact_count":impact_count,"up":global_basis.y.dot(Vector3.UP)}

func _apply_structure_force(state: PhysicsDirectBodyState3D, force: Vector3, offset: Vector3) -> void:
	applied_structure_force+=force
	applied_structure_torque+=(offset-state.transform.basis*center_of_mass).cross(force)
	state.apply_force(force,offset)
