extends Node

# Nodal mass, elastic beams, plastic deformation and complete body contacts
# share one physical state. Jolt supplies geometric queries and carries the
# solved rigid pose; its chassis collision response is disabled.
const Z_STATIONS: Array[float]=[-2.25,-1.65,-0.8,0.0,0.9,1.65,2.25]
const TOTAL_MASS: float=1360.0
var rest: PackedVector3Array=PackedVector3Array()
var nodes: PackedVector3Array=PackedVector3Array()
var velocities: PackedVector3Array=PackedVector3Array()
var constraint_displacements: PackedVector3Array=PackedVector3Array()
var masses: PackedFloat32Array=PackedFloat32Array()
var inv_masses: PackedFloat32Array=PackedFloat32Array()
var loads: PackedVector3Array=PackedVector3Array()
var beams: Array=[]
var beam_a: PackedInt32Array=PackedInt32Array()
var beam_b: PackedInt32Array=PackedInt32Array()
var beam_lengths: PackedFloat64Array=PackedFloat64Array()
var beam_originals: PackedFloat64Array=PackedFloat64Array()
var beam_stiffness: PackedFloat64Array=PackedFloat64Array()
var beam_yield: PackedFloat64Array=PackedFloat64Array()
var beam_yield_extension: PackedFloat64Array=PackedFloat64Array()
var beam_lambdas: PackedFloat64Array=PackedFloat64Array()
var beam_broken: PackedByteArray=PackedByteArray()
var beam_compliance: PackedFloat64Array=PackedFloat64Array()
var beam_denominator: PackedFloat64Array=PackedFloat64Array()
var beam_damping: PackedFloat64Array=PackedFloat64Array()
var cached_h: float=-1.0
var pieces: Array=[]
var root: Node3D
var skeleton: Skeleton3D
var center: Vector3=Vector3.ZERO
var inertia: Vector3=Vector3.ZERO
var active_time: float=0.0
var accumulator: float=0.0
var maximum_displacement: float=0.0
var broken_beams: int=0
var plastic_work: float=0.0
var shattered: bool=false
var load_total: Vector3=Vector3.ZERO
var load_torque: Vector3=Vector3.ZERO
var nodal_collision_enabled: bool=false
var full_body_contacts_enabled: bool=false
var reporting_contact: bool=false
var previous_world: PackedVector3Array=PackedVector3Array()
var contact_cooldown: float=0.0
var contacts: Array[Dictionary]=[]
var query_hulls: Array[ConvexPolygonShape3D]=[]
var query_materials: Array[PackedVector3Array]=[]
var query_bindings: Array[Array]=[]
var broadphase_shapes: Array[BoxShape3D]=[]
var broadphase_sizes: Array[Vector3]=[]
var broadphase_centers: Array[Vector3]=[]
var frame_recovery_count: int=0
var node_recovery_count: int=0
var alignment_recovery_count: int=0
var contact_impulse_total: float=0.0
var contact_friction_impulse_total: float=0.0
var contact_point_total: Vector3=Vector3.ZERO
var contact_normal_total: Vector3=Vector3.ZERO
var contact_peak_speed: float=0.0
var plastic_energy: float=0.0
var substep_old: PackedVector3Array=PackedVector3Array()
var position_repairs: PackedVector3Array=PackedVector3Array()
var velocity_impulses: PackedVector3Array=PackedVector3Array()
var position_contact_total: float=0.0
var initial_overlap_recovery: bool=true
var triangle_face_cache: Dictionary={}
var unmapped_contact_count: int=0
var swept_sample_contact_count: int=0

func setup(model: Node3D) -> void:
	root=model
	skeleton=Skeleton3D.new()
	skeleton.name="Structure"
	root.add_child(skeleton)
	for z: float in Z_STATIONS:
		for y: float in [0.42,0.88,1.34]:
			for x: float in [-0.82,0.0,0.82]:
				var p: Vector3=Vector3(x,y,z)
				var index: int=nodes.size()
				rest.append(p)
				nodes.append(p)
				velocities.append(Vector3.ZERO)
				constraint_displacements.append(Vector3.ZERO)
				loads.append(Vector3.ZERO)
				var weight: float=4.3 if y<0.5 else (1.0 if y<1.0 else 0.30)
				if z < -0.8 and y<1.0: weight*=1.15
				masses.append(weight)
				skeleton.add_bone("node_%02d"%index)
				skeleton.set_bone_rest(index,Transform3D(Basis.IDENTITY,p))
				skeleton.set_bone_pose_position(index,p)
	var sum_mass: float=0
	for value: float in masses: sum_mass+=value
	for i: int in range(nodes.size()):
		masses[i]*=TOTAL_MASS/sum_mass
		inv_masses.append(1.0/masses[i])
		center+=rest[i]*masses[i]/TOTAL_MASS
	for i: int in range(nodes.size()):
		var r: Vector3=rest[i]-center
		inertia+=Vector3(r.y*r.y+r.z*r.z,r.x*r.x+r.z*r.z,r.x*r.x+r.y*r.y)*masses[i]
	for a: int in range(nodes.size()):
		for b: int in range(a+1,nodes.size()):
			var length: float=nodes[a].distance_to(nodes[b])
			if length>1.24: continue
			var middle: Vector3=(rest[a]+rest[b])*0.5
			var crumple: bool=absf(middle.z)>1.0
			var stiffness: float=300000.0 if crumple else 2600000.0
			var yield_force: float=4500.0 if crumple else 115000.0
			if middle.y>1.05:
				stiffness*=0.42
				yield_force*=0.35
			# Pillar and suspension braces support the standing vehicle; the
			# longitudinal rails retain their lower crash-yield threshold.
			if crumple and absf(rest[b].y-rest[a].y)>0.25: yield_force=maxf(yield_force,6300.0)
			beams.append({"a":a,"b":b,"length":length,"original":length,"stiffness":stiffness,"yield":yield_force,"lambda":0.0,"broken":false})
	_initialize_beam_cache()
	_collect(model)
	_update_meshes()
	for section: int in range(2):
		var hull: ConvexPolygonShape3D=ConvexPolygonShape3D.new()
		hull.margin=0.003
		query_hulls.append(hull)
		var broadphase: BoxShape3D=BoxShape3D.new()
		broadphase.size=Vector3(1.88,0.82,1.48)
		broadphase_shapes.append(broadphase)
		broadphase_sizes.append(broadphase.size)
		broadphase_centers.append(Vector3(0,0.66,-1.64 if section==0 else 1.64))
		var surface: PackedVector3Array=PackedVector3Array()
		var sign_z: float=-1 if section==0 else 1
		for z: float in [0.96,1.65,2.25,2.32]:
			for y: float in [0.31,0.42,0.88,1.02]:
				for x: float in [-0.90,-0.82,0.0,0.82,0.90]:
					surface.append(Vector3(x,y,z*sign_z))
		query_materials.append(surface)
		var bindings: Array=[]
		for point: Vector3 in surface:
			var binding: Array=_weights(point)
			var represented: Vector3=Vector3.ZERO
			for i: int in range(8): represented+=rest[binding[0][i]]*binding[1][i]
			bindings.append({"weights":binding,"offset":point-represented})
		query_bindings.append(bindings)

func _add_query_envelope(surface: PackedVector3Array, size: Vector3, at: Vector3) -> void:
	var hull: ConvexPolygonShape3D=ConvexPolygonShape3D.new()
	hull.margin=0.003
	query_hulls.append(hull)
	query_materials.append(surface)
	var bindings: Array=[]
	for point: Vector3 in surface:
		var binding: Array=_weights(point)
		var represented: Vector3=Vector3.ZERO
		for i: int in range(8): represented+=rest[binding[0][i]]*binding[1][i]
		bindings.append({"weights":binding,"offset":point-represented})
	query_bindings.append(bindings)
	var broadphase: BoxShape3D=BoxShape3D.new()
	broadphase.size=size
	broadphase_shapes.append(broadphase)
	broadphase_sizes.append(size)
	broadphase_centers.append(at)

func enable_full_body_contacts() -> void:
	if full_body_contacts_enabled: return
	full_body_contacts_enabled=true
	var middle: PackedVector3Array=PackedVector3Array()
	for z: float in [-0.96,-0.8,0.0,0.9,0.96]:
		for y: float in [0.28,0.42,0.88,1.04]:
			for x: float in [-0.91,-0.82,0.0,0.82,0.91]:
				middle.append(Vector3(x,y,z))
	_add_query_envelope(middle,Vector3(1.92,0.88,2.04),Vector3(0,0.66,0))
	# Follow the actual windshield, roof, and rear glass silhouette. The
	# structural grid above the hood is not part of the exterior envelope.
	var upper: PackedVector3Array=PackedVector3Array()
	for z: float in [-0.67,-0.4,-0.138,0.0,0.45,0.862,1.16,1.42]:
		var top: float=1.43
		if z< -0.138: top=lerpf(1.04,1.43,(z+0.67)/0.532)
		elif z>0.862: top=lerpf(1.43,1.05,(z-0.862)/0.558)
		for fraction: float in [0.0,0.5,1.0]:
			var y: float=lerpf(1.02,top,fraction)
			var width: float=lerpf(0.845,0.683,clampf((y-1.02)/0.41,0,1))
			for x: float in [-1.0,-0.6,0.0,0.6,1.0]: upper.append(Vector3(x*width,y,z))
	_add_query_envelope(upper,Vector3(1.81,0.53,2.21),Vector3(0,1.225,0.375))
	# Jolt carries the shared rigid momentum; the complete exterior now owns
	# collision response. Keep inertial geometry while disabling its contacts.
	get_parent().collision_layer=0
	get_parent().collision_mask=0
	contacts.clear()

func _initialize_beam_cache() -> void:
	for beam: Dictionary in beams:
		beam_a.append(beam.a)
		beam_b.append(beam.b)
		beam_lengths.append(beam.length)
		beam_originals.append(beam.original)
		beam_stiffness.append(beam.stiffness)
		beam_yield.append(beam.yield)
		beam_yield_extension.append(beam.yield/beam.stiffness)
		beam_lambdas.append(0.0)
		beam_broken.append(0)
	beam_compliance.resize(beams.size())
	beam_denominator.resize(beams.size())
	beam_damping.resize(beams.size())

func _prepare_beam_step(h: float) -> void:
	if h==cached_h: return
	cached_h=h
	for i: int in range(beam_a.size()):
		var inverse_mass: float=inv_masses[beam_a[i]]+inv_masses[beam_b[i]]
		beam_compliance[i]=1.0/(beam_stiffness[i]*h*h)
		beam_denominator[i]=inverse_mass+beam_compliance[i]
		var damping: float=0.22*2.0*sqrt(beam_stiffness[i]/inverse_mass)
		beam_damping[i]=(1.0-exp(-damping*inverse_mass*h))/inverse_mass

func _solve_beams() -> void:
	for i: int in range(beam_a.size()):
		if beam_broken[i]!=0: continue
		var a: int=beam_a[i]
		var b: int=beam_b[i]
		var offset: Vector3=nodes[b]-nodes[a]
		var distance: float=offset.length()
		if distance<0.00001: continue
		var correction: float=(-(distance-beam_lengths[i])-beam_compliance[i]*beam_lambdas[i])/beam_denominator[i]
		beam_lambdas[i]+=correction
		var normal: Vector3=offset/distance
		var move_a: Vector3=-normal*correction*inv_masses[a]
		var move_b: Vector3=normal*correction*inv_masses[b]
		nodes[a]+=move_a
		nodes[b]+=move_b
		constraint_displacements[a]+=move_a
		constraint_displacements[b]+=move_b

func _update_plasticity(h: float) -> void:
	var flow: float=minf(h*160.0,1.0)
	for i: int in range(beam_a.size()):
		if beam_broken[i]!=0: continue
		var distance: float=nodes[beam_a[i]].distance_to(nodes[beam_b[i]])
		var extension: float=distance-beam_lengths[i]
		var yield_extension: float=beam_yield_extension[i]
		if absf(extension)>yield_extension:
			var plastic: float=(extension-signf(extension)*yield_extension)*flow
			var old_length: float=beam_lengths[i]
			beam_lengths[i]=clampf(old_length+plastic,beam_originals[i]*0.2,beam_originals[i]*1.8)
			plastic_work+=absf(beam_lengths[i]-old_length)*beam_yield[i]
			plastic_energy+=maxf(0,0.5*beam_stiffness[i]*(extension*extension-pow(distance-beam_lengths[i],2)))
		if distance>beam_originals[i]*1.55 and absf(beam_lambdas[i])/(h*h)>beam_yield[i]*2.2:
			beam_broken[i]=1
			broken_beams+=1

func _damp_beams() -> void:
	for i: int in range(beam_a.size()):
		if beam_broken[i]!=0: continue
		var a: int=beam_a[i]
		var b: int=beam_b[i]
		var normal: Vector3=(nodes[b]-nodes[a]).normalized()
		var impulse: float=-(velocities[b]-velocities[a]).dot(normal)*beam_damping[i]
		velocities[a]-=normal*impulse*inv_masses[a]
		velocities[b]+=normal*impulse*inv_masses[b]

func _publish_beams() -> void:
	# Public beam dictionaries are inspection records; solve from typed storage.
	for i: int in range(beams.size()):
		beams[i].length=beam_lengths[i]
		beams[i].lambda=beam_lambdas[i]
		beams[i].broken=beam_broken[i]!=0

func _weights(point: Vector3) -> Array:
	var xf: float=clampf((point.x+0.82)/0.82,0,2)
	var yf: float=clampf((point.y-0.42)/0.46,0,2)
	var xi: int=mini(int(xf),1)
	var yi: int=mini(int(yf),1)
	var zi: int=0
	while zi<5 and point.z>Z_STATIONS[zi+1]: zi+=1
	var tx: float=xf-xi
	var ty: float=yf-yi
	var tz: float=clampf((point.z-Z_STATIONS[zi])/(Z_STATIONS[zi+1]-Z_STATIONS[zi]),0,1)
	var indices: PackedInt32Array=PackedInt32Array()
	var weights: PackedFloat32Array=PackedFloat32Array()
	for z: int in range(2):
		for y: int in range(2):
			for x: int in range(2):
				indices.append((zi+z)*9+(yi+y)*3+xi+x)
				weights.append((tx if x else 1-tx)*(ty if y else 1-ty)*(tz if z else 1-tz))
	return [indices,weights]

func _collect(node: Node) -> void:
	if node==skeleton or String(node.name).begins_with("Wheel_") or String(node.name) in ["SteeringWheel","Needle_Speed","Needle_RPM"]:
		return
	if node is MeshInstance3D and node.mesh:
		var mesh_node: MeshInstance3D=node
		var relative: Transform3D=root.global_transform.affine_inverse()*mesh_node.global_transform
		var mesh: ArrayMesh=ArrayMesh.new()
		var skin: Skin=Skin.new()
		for i: int in range(rest.size()):
			skin.add_bind(i,Transform3D(Basis.IDENTITY,-rest[i])*relative)
		for surface: int in range(mesh_node.mesh.get_surface_count()):
			var arrays: Array=mesh_node.mesh.surface_get_arrays(surface)
			if arrays.is_empty(): continue
			var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var bones: PackedInt32Array=PackedInt32Array()
			var weights: PackedFloat32Array=PackedFloat32Array()
			bones.resize(vertices.size()*8)
			weights.resize(vertices.size()*8)
			for v: int in range(vertices.size()):
				var binding: Array=_weights(relative*vertices[v])
				for j: int in range(8):
					bones[v*8+j]=binding[0][j]
					weights[v*8+j]=binding[1][j]
			arrays[Mesh.ARRAY_BONES]=bones
			arrays[Mesh.ARRAY_WEIGHTS]=weights
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{},Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
			mesh.surface_set_material(mesh.get_surface_count()-1,mesh_node.mesh.surface_get_material(surface))
		pieces.append({"node":mesh_node,"original":mesh_node.mesh})
		mesh_node.mesh=mesh
		mesh_node.skin=skin
		mesh_node.skeleton=mesh_node.get_path_to(skeleton)
		mesh_node.extra_cull_margin=3.0
	for child: Node in node.get_children(): _collect(child)

func add_load(point: Vector3,force: Vector3) -> void:
	if not force.is_finite(): return
	var weights: Array=_weights(point)
	for i: int in range(8): loads[weights[0][i]]+=force*weights[1][i]
	load_total+=force
	var attachment: Vector3=point+displacement_at(point)
	load_torque+=(attachment-center).cross(force)
	if force.length()>100: active_time=maxf(active_time,0.15)

func impact(point: Vector3,direction: Vector3,strength: float) -> void:
	if reporting_contact: return
	if not point.is_finite() or not direction.is_finite(): return
	point=point.clamp(Vector3(-1,0.25,-2.35),Vector3(1,1.5,2.35))
	var speed: float=strength/0.055
	var impulse: Vector3=direction.normalized()*TOTAL_MASS*speed
	var weights: Array=_weights(point)
	var dv: PackedVector3Array=PackedVector3Array()
	dv.resize(nodes.size())
	for i: int in range(8): dv[weights[0][i]]+=impulse*weights[1][i]*inv_masses[weights[0][i]]
	var translation: Vector3=impulse/TOTAL_MASS
	var angular: Vector3=(point-center).cross(impulse)/inertia
	var energy: float=0
	var cross_energy: float=0
	for i: int in range(nodes.size()):
		dv[i]-=translation+angular.cross(rest[i]-center)
		energy+=0.5*masses[i]*dv[i].length_squared()
		cross_energy+=masses[i]*velocities[i].dot(dv[i])
	var budget: float=0.5*TOTAL_MASS*speed*speed*0.68
	var factor: float=1.0
	if energy+cross_energy>budget:
		factor=clampf((-cross_energy+sqrt(cross_energy*cross_energy+4.0*energy*budget))/maxf(2.0*energy,0.01),0,1)
	for i: int in range(nodes.size()): velocities[i]+=dv[i]*factor
	active_time=3.0
	if strength>0.45 and point.y>0.8: shattered=true

func _material_point(binding: Array, offset: Vector3=Vector3.ZERO) -> Vector3:
	var point: Vector3=offset
	for i: int in range(8): point+=nodes[binding[0][i]]*binding[1][i]
	return point

func _contact_query(shape: Shape3D, pose: Transform3D, motion: Vector3=Vector3.ZERO) -> PhysicsShapeQueryParameters3D:
	var query: PhysicsShapeQueryParameters3D=PhysicsShapeQueryParameters3D.new()
	query.shape=shape
	query.transform=pose
	query.motion=motion
	query.collision_mask=1
	var exclusions: Array[RID]=[get_parent().get_rid()]
	for part: Node3D in get_parent().debris:
		if is_instance_valid(part) and part is CollisionObject3D: exclusions.append(part.get_rid())
	query.exclude=exclusions
	query.margin=0.002
	return query

func _append_contact(material: Vector3, plane: Vector3, normal: Vector3, info: Dictionary) -> void:
	if not full_body_contacts_enabled and absf(material.z)<0.94: return
	for existing: Dictionary in contacts:
		if existing.collider_id==info.collider_id and Vector3(existing.material).distance_squared_to(material)<0.09*0.09 and Vector3(existing.normal).dot(normal)>0.99:
			existing.plane=plane
			existing.age=0.0
			return
	var binding: Array=_weights(material)
	var represented: Vector3=Vector3.ZERO
	var effective_inverse: float=0.0
	for i: int in range(8):
		represented+=rest[binding[0][i]]*binding[1][i]
		effective_inverse+=binding[1][i]*binding[1][i]*inv_masses[binding[0][i]]
	var friction: float=0.45
	var body_material: PhysicsMaterial=get_parent().physics_material_override
	if body_material: friction=body_material.friction
	var collider: Object=instance_from_id(info.collider_id)
	if collider is PhysicsBody3D:
		var surface_material: PhysicsMaterial=collider.physics_material_override
		if surface_material: friction=minf(friction,surface_material.friction)
	contacts.append({"material":material,"binding":binding,"offset":material-represented,"normal":normal,"plane":plane,"inverse_mass":effective_inverse,"friction":friction,"lambda":0.0,"age":0.0,"collider_velocity":info.get("linear_velocity",Vector3.ZERO),"collider_id":info.collider_id})

func _inside_contact_face(point: Vector3, normal: Vector3, plane: Vector3, collider: Object, validate_solid_depth: bool=false) -> bool:
	var projected: Vector3=point-normal*(point-plane).dot(normal)-normal*0.001
	var known_surface: bool=false
	if collider is Node3D:
		for child: Node in collider.get_children():
			if child is CollisionShape3D and not child.disabled and child.shape is BoxShape3D:
				known_surface=true
				var at: Vector3=child.global_transform.affine_inverse()*projected
				var extent: Vector3=child.shape.size*0.5+Vector3.ONE*0.006
				if absf(at.x)>extent.x or absf(at.y)>extent.y or absf(at.z)>extent.z: continue
				if validate_solid_depth:
					# A convex envelope may surround a narrow obstacle after
					# folding. Material already beyond its opposite face is
					# outside that solid, not deeply behind this entry face.
					var local_normal: Vector3=(child.global_basis.transposed()*normal).normalized()
					var local_point: Vector3=child.global_transform.affine_inverse()*point
					var half_span: float=local_normal.abs().dot(child.shape.size*0.5)
					if local_normal.dot(local_point)<-half_span-0.006: continue
				return true
			elif child is CollisionShape3D and not child.disabled and child.shape is ConcavePolygonShape3D:
				known_surface=true
				var at: Vector3=child.global_transform.affine_inverse()*projected
				var normal_basis: Basis=child.global_basis.inverse().transposed()
				for face: Dictionary in _triangle_faces(child.shape):
					if at.distance_squared_to(at.clamp(face.minimum-Vector3.ONE*0.007,face.maximum+Vector3.ONE*0.007))>0.00000001: continue
					var face_normal: Vector3=(normal_basis*Vector3(face.normal)).normalized()
					if face_normal.dot(normal)<0.9995: continue
					if absf((child.global_transform*Vector3(face.a)-plane).dot(normal))>0.006: continue
					if _closest_triangle_point(at,face).distance_squared_to(at)<0.007*0.007: return true
		if known_surface: return false
		# A short normal ray checks the real finite triangle or curved surface.
		# Retaining an infinite tangent plane would catch the car beyond an edge.
		var ray: PhysicsRayQueryParameters3D=PhysicsRayQueryParameters3D.create(projected+normal*0.026,projected-normal*0.025,1,[get_parent().get_rid()])
		var hit: Dictionary=get_parent().get_world_3d().direct_space_state.intersect_ray(ray)
		return not hit.is_empty() and hit.collider_id==collider.get_instance_id() and Vector3(hit.normal).dot(normal)>0.9995
	return false

func _triangle_faces(shape: ConcavePolygonShape3D) -> Array:
	var key: int=shape.get_instance_id()
	if triangle_face_cache.has(key): return triangle_face_cache[key]
	var faces: Array=[]
	var vertices: PackedVector3Array=shape.get_faces()
	for i: int in range(0,vertices.size()-2,3):
		var a: Vector3=vertices[i]
		var b: Vector3=vertices[i+1]
		var c: Vector3=vertices[i+2]
		var cross: Vector3=(b-a).cross(c-a)
		if cross.length_squared()<0.0000000001: continue
		# Godot collision faces use clockwise front-face winding.
		faces.append({"a":a,"b":b,"c":c,"cross":cross,"normal":-cross.normalized(),"minimum":a.min(b).min(c),"maximum":a.max(b).max(c)})
	triangle_face_cache[key]=faces
	return faces

func _closest_triangle_point(point: Vector3, face: Dictionary) -> Vector3:
	var a: Vector3=face.a
	var b: Vector3=face.b
	var c: Vector3=face.c
	var normal: Vector3=face.normal
	var projected: Vector3=point-normal*(point-a).dot(normal)
	var cross: Vector3=face.cross
	if cross.dot((b-a).cross(projected-a))>=-0.00000001 and cross.dot((c-b).cross(projected-b))>=-0.00000001 and cross.dot((a-c).cross(projected-c))>=-0.00000001: return projected
	var best: Vector3=a
	for edge: Array in [[a,b],[b,c],[c,a]]:
		var direction: Vector3=Vector3(edge[1])-Vector3(edge[0])
		var closest: Vector3=Vector3(edge[0])+direction*clampf((point-Vector3(edge[0])).dot(direction)/maxf(direction.length_squared(),0.0000000001),0,1)
		if point.distance_squared_to(closest)<point.distance_squared_to(best): best=closest
	return best

func _surface_normal(point: Vector3, approximate: Vector3, collider: Object) -> Vector3:
	var best_distance: float=INF
	var best: Vector3=Vector3.ZERO
	if collider is Node3D:
		for child: Node in collider.get_children():
			if child is CollisionShape3D and not child.disabled and child.shape is BoxShape3D:
				var at: Vector3=child.global_transform.affine_inverse()*point
				var half: Vector3=child.shape.size*0.5
				for axis: int in range(3):
					var local_normal: Vector3=Vector3.ZERO
					local_normal[axis]=1.0 if at[axis]>=0 else -1.0
					var candidate: Vector3=(child.global_basis.inverse().transposed()*local_normal).normalized()
					var distance: float=absf(absf(at[axis])-half[axis])
					if candidate.dot(approximate)>0.5 and distance<best_distance:
						best_distance=distance
						best=candidate
			elif child is CollisionShape3D and not child.disabled and child.shape is ConcavePolygonShape3D:
				var at: Vector3=child.global_transform.affine_inverse()*point
				var normal_basis: Basis=child.global_basis.inverse().transposed()
				for face: Dictionary in _triangle_faces(child.shape):
					if at.distance_squared_to(at.clamp(face.minimum,face.maximum))>0.04*0.04: continue
					var candidate: Vector3=(normal_basis*Vector3(face.normal)).normalized()
					var alignment: float=candidate.dot(approximate)
					if alignment<0.25: continue
					var closest: Vector3=child.global_transform*_closest_triangle_point(at,face)
					var distance: float=closest.distance_to(point)+(1.0-alignment)*0.00001
					if distance<best_distance:
						best_distance=distance
						best=candidate
		if best_distance<0.04: return best
		var ray: PhysicsRayQueryParameters3D=PhysicsRayQueryParameters3D.create(point+approximate*0.03,point-approximate*0.03,1,[get_parent().get_rid()])
		var hit: Dictionary=get_parent().get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty() and hit.collider_id==collider.get_instance_id() and Vector3(hit.normal).dot(approximate)>0.5: return hit.normal
	return Vector3.ZERO

func _support_hull(points: PackedVector3Array) -> PackedVector3Array:
	# Keep directional support vertices; nearly coplanar interior samples make
	# Jolt's runtime hull builder unreliable after a heavily folded panel.
	var hull: PackedVector3Array=PackedVector3Array()
	for x: int in [-1,0,1]:
		for y: int in [-1,0,1]:
			for z: int in [-1,0,1]:
				if x==0 and y==0 and z==0: continue
				var direction: Vector3=Vector3(x,y,z)
				var support: Vector3=points[0]
				for point: Vector3 in points:
					if point.dot(direction)>support.dot(direction): support=point
				var duplicate: bool=false
				for point: Vector3 in hull:
					if point.distance_squared_to(support)<0.000001:
						duplicate=true
						break
				if not duplicate: hull.append(support)
	return hull

func _query_material_coordinate(point: Vector3, section: int, deformed: PackedVector3Array) -> Dictionary:
	var original: PackedVector3Array=query_materials[section]
	var minimum: Vector3=original[0]
	var maximum: Vector3=original[0]
	var nearest: int=0
	for i: int in range(original.size()):
		minimum=minimum.min(original[i])
		maximum=maximum.max(original[i])
		if deformed[i].distance_squared_to(point)<deformed[nearest].distance_squared_to(point): nearest=i
	var best: Vector3=original[nearest]
	var best_error: float=INF
	# A deformed query hull can bridge a folded surface. A contact is valid
	# only if its material coordinate actually maps back to the query point.
	for seed: Vector3 in [point.clamp(minimum,maximum),original[nearest]]:
		var material: Vector3=seed
		for iteration: int in range(10):
			var residual: Vector3=material+displacement_at(material)-point
			var error: float=residual.length_squared()
			if error<best_error:
				best_error=error
				best=material
			if error<=0.002*0.002: return {"valid":true,"material":material,"error":sqrt(error)}
			var derivative: Basis=deformation_gradient(material)
			# Displacement interpolation clamps outside the nodal lattice;
			# the geometric envelope offset continues with identity derivative.
			if material.x<=-0.82 or material.x>=0.82: derivative.x=Vector3.RIGHT
			if material.y<=0.42 or material.y>=1.34: derivative.y=Vector3.UP
			if material.z<=Z_STATIONS[0] or material.z>=Z_STATIONS[-1]: derivative.z=Vector3.BACK
			if not derivative.is_finite() or absf(derivative.determinant())<0.000001: break
			var step: Vector3=(derivative.inverse()*residual).limit_length(0.5)
			var improved: bool=false
			for backtrack: int in range(6):
				var candidate: Vector3=(material-step).clamp(minimum,maximum)
				if (candidate+displacement_at(candidate)-point).length_squared()<error:
					material=candidate
					improved=true
					break
				step*=0.5
			if not improved: break
	unmapped_contact_count+=1
	return {"valid":false,"material":best,"error":sqrt(best_error)}

func _sweep_material_samples(space: PhysicsDirectSpaceState3D, pose: Transform3D, section: int, points: PackedVector3Array, exclusions: Array[RID]) -> void:
	if substep_old.size()!=nodes.size(): return
	var original: PackedVector3Array=query_materials[section]
	for i: int in range(points.size()):
		var binding: Dictionary=query_bindings[section][i]
		var old_point: Vector3=binding.offset
		for j: int in range(8): old_point+=substep_old[binding.weights[0][j]]*binding.weights[1][j]
		var from: Vector3=pose*old_point
		var to: Vector3=pose*points[i]
		if from.distance_squared_to(to)<0.0000000001: continue
		var ray: PhysicsRayQueryParameters3D=PhysicsRayQueryParameters3D.create(from,to,1,exclusions)
		var hit: Dictionary=space.intersect_ray(ray)
		if hit.is_empty() or Vector3(hit.normal).length_squared()<0.5: continue
		# The reduced convex query can omit a deformed support vertex.
		# Trace the actual material trajectory so it cannot cross a finite
		# surface unnoticed and accumulate penetration over later steps.
		_append_contact(original[i],hit.position,hit.normal,hit)
		swept_sample_contact_count+=1

func _gather_contacts(state: PhysicsDirectBodyState3D, pose: Transform3D, previous_pose: Transform3D, h: float, sweep_time: float, detect: bool) -> void:
	var retained: Array[Dictionary]=[]
	for contact: Dictionary in contacts:
		contact.plane+=contact.collider_velocity*h
		var point: Vector3=pose*_material_point(contact.binding,contact.offset)
		var collider: Object=instance_from_id(contact.collider_id)
		var within_face: bool=collider!=null and _inside_contact_face(point,contact.normal,contact.plane,collider)
		if within_face and (point-Vector3(contact.plane)).dot(contact.normal)<0.025+state.linear_velocity.length()*state.step and contact.age<0.4:
			contact.age+=h
			contact.lambda=0.0
			retained.append(contact)
	contacts=retained
	if not detect: return
	var space: PhysicsDirectSpaceState3D=state.get_space_state()
	for section: int in range(query_hulls.size()):
		var broadphase: BoxShape3D=broadphase_shapes[section]
		broadphase.size=broadphase_sizes[section]+Vector3.ONE*maxf(maximum_displacement-0.005,0)*2.0
		var displacement_center: Vector3=Vector3.ZERO
		for n: int in range(nodes.size()): displacement_center+=(nodes[n]-rest[n])*masses[n]/TOTAL_MASS
		broadphase.size+=Vector3.ONE*state.angular_velocity.length()*3.0*sweep_time
		var broad_pose: Transform3D=previous_pose.translated_local(broadphase_centers[section]+displacement_center)
		var broad_query: PhysicsShapeQueryParameters3D=_contact_query(broadphase,broad_pose,state.linear_velocity*sweep_time)
		if space.get_rest_info(broad_query).is_empty():
			var broad_fraction: PackedFloat32Array=space.cast_motion(broad_query)
			if broad_fraction.size()<2 or broad_fraction[0]>=1: continue
		var original: PackedVector3Array=query_materials[section]
		var points: PackedVector3Array=original.duplicate()
		for i: int in range(points.size()): points[i]=_material_point(query_bindings[section][i].weights,query_bindings[section][i].offset)
		_sweep_material_samples(space,pose,section,points,broad_query.exclude)
		query_hulls[section].points=_support_hull(points)
		var query: PhysicsShapeQueryParameters3D=_contact_query(query_hulls[section],pose)
		var info: Dictionary=space.get_rest_info(query)
		var hit_pose: Transform3D=pose
		if info.is_empty():
			var travel: Vector3=state.linear_velocity*sweep_time
			if travel.length_squared()<0.0000001: continue
			query.transform=previous_pose
			query.motion=travel+travel.normalized()*0.003
			var fraction: PackedFloat32Array=space.cast_motion(query)
			if fraction.size()<2 or fraction[0]>=1: continue
			query.transform.origin=previous_pose.origin+query.motion*fraction[1]+travel.normalized()*0.003
			query.motion=Vector3.ZERO
			info=space.get_rest_info(query)
			hit_pose=query.transform
		if info.is_empty(): continue
		# collide_shape does not label its pairs. Isolate each body so a wall
		# normal can never be assigned to a simultaneous floor contact.
		var candidates: Array[Dictionary]=space.intersect_shape(query,64)
		var owners: Dictionary={}
		for candidate: Dictionary in candidates: owners[candidate.rid]=candidate
		if owners.is_empty(): owners[info.rid]={"rid":info.rid,"collider_id":info.collider_id}
		for owner_rid: RID in owners:
			var owned: PhysicsShapeQueryParameters3D=_contact_query(query.shape,query.transform)
			var exclusions: Array[RID]=owned.exclude
			for other_rid: RID in owners:
				if other_rid!=owner_rid: exclusions.append(other_rid)
			owned.exclude=exclusions
			var owned_info: Dictionary=space.get_rest_info(owned)
			if owned_info.is_empty(): continue
			var collider: Object=instance_from_id(owned_info.collider_id)
			var pairs: PackedVector3Array=space.collide_shape(owned,24)
			if pairs.is_empty(): pairs=PackedVector3Array([owned_info.point,owned_info.point])
			var planes: Array[Dictionary]=[]
			for pair: int in range(0,pairs.size()-1,2):
				var normal: Vector3=pairs[pair+1]-pairs[pair]
				normal=normal.normalized() if normal.length_squared()>0.00000001 else Vector3(owned_info.normal)
				normal=_surface_normal(pairs[pair+1],normal,collider)
				if normal.length_squared()<0.5 or not _inside_contact_face(pairs[pair+1],normal,pairs[pair+1],collider): continue
				var local_hit: Vector3=hit_pose.affine_inverse()*pairs[pair]
				var mapped: Dictionary=_query_material_coordinate(local_hit,section,points)
				if mapped.valid:
					var material: Vector3=mapped.material
					var represented: Vector3=hit_pose*(material+displacement_at(material))
					if _inside_contact_face(represented,normal,pairs[pair+1],collider,true):
						_append_contact(material,pairs[pair+1],normal,owned_info)
				var unique: bool=true
				for plane: Dictionary in planes:
					if Vector3(plane.normal).dot(normal)>0.9995 and absf((pairs[pair+1]-Vector3(plane.point)).dot(normal))<0.003:
						unique=false
						break
				if unique: planes.append({"normal":normal,"point":pairs[pair+1]})
			# Include bowed material-cell centers, bounded by the owner's face.
			for plane: Dictionary in planes:
				for i: int in range(original.size()):
					var point: Vector3=hit_pose*points[i]
					if (point-Vector3(plane.point)).dot(plane.normal)>0.004: continue
					if _inside_contact_face(point,plane.normal,plane.point,collider,true): _append_contact(original[i],plane.point,plane.normal,owned_info)

func integrate_contacts(state: PhysicsDirectBodyState3D,dt: float) -> void:
	if nodal_collision_enabled: _simulate(dt,state)

func _physics_process(dt: float) -> void:
	if not nodal_collision_enabled: _simulate(dt)

func _motion_of_nodes() -> Dictionary:
	var at: Vector3=Vector3.ZERO
	var speed: Vector3=Vector3.ZERO
	for i: int in range(nodes.size()):
		at+=nodes[i]*masses[i]/TOTAL_MASS
		speed+=velocities[i]*masses[i]/TOTAL_MASS
	var angular_momentum: Vector3=Vector3.ZERO
	var ix: Vector3=Vector3.ZERO
	var iy: Vector3=Vector3.ZERO
	var iz: Vector3=Vector3.ZERO
	for i: int in range(nodes.size()):
		var r: Vector3=nodes[i]-at
		var m: float=masses[i]
		angular_momentum+=r.cross(velocities[i]-speed)*m
		ix+=Vector3(r.y*r.y+r.z*r.z,-r.x*r.y,-r.x*r.z)*m
		iy+=Vector3(-r.x*r.y,r.x*r.x+r.z*r.z,-r.y*r.z)*m
		iz+=Vector3(-r.x*r.z,-r.y*r.z,r.x*r.x+r.y*r.y)*m
	var tensor: Basis=Basis(ix,iy,iz)
	var omega: Vector3=Vector3.ZERO
	if tensor.is_finite() and tensor.determinant()>0.00001: omega=tensor.inverse()*angular_momentum
	else: frame_recovery_count+=1
	return {"center":at,"velocity":speed,"omega":omega,"inertia":tensor}

func _solve_contacts(state: PhysicsDirectBodyState3D, pose: Transform3D, h: float) -> Transform3D:
	for contact: Dictionary in contacts:
		var world_point: Vector3=pose*_material_point(contact.binding,contact.offset)
		var normal: Vector3=contact.normal
		var constraint: float=(world_point-Vector3(contact.plane)).dot(normal)-0.002
		if constraint>=0: continue
		var collider: Object=instance_from_id(contact.collider_id)
		if collider==null or not _inside_contact_face(world_point,normal,contact.plane,collider): continue
		var correction: float=-constraint/maxf(contact.inverse_mass,0.000001)
		var local_normal: Vector3=pose.basis.inverse()*normal
		var point_velocity: Vector3=Vector3.ZERO
		for i: int in range(8): point_velocity+=velocities[contact.binding[0][i]]*contact.binding[1][i]
		var closing: float=maxf(0,-(pose.basis*point_velocity-Vector3(contact.collider_velocity)).dot(normal))
		contact_peak_speed=maxf(contact_peak_speed,closing)
		contact.lambda+=correction
		for i: int in range(8):
			var index: int=contact.binding[0][i]
			var move: Vector3=local_normal*correction*contact.binding[1][i]*inv_masses[index]
			nodes[index]+=move
			constraint_displacements[index]+=move
	return pose

func _contact_friction(pose: Transform3D, h: float) -> void:
	for contact: Dictionary in contacts:
		if contact.lambda<=0: continue
		var point_velocity: Vector3=Vector3.ZERO
		for i: int in range(8): point_velocity+=velocities[contact.binding[0][i]]*contact.binding[1][i]
		var world_velocity: Vector3=pose.basis*point_velocity-Vector3(contact.collider_velocity)
		var tangent: Vector3=world_velocity-Vector3(contact.normal)*world_velocity.dot(contact.normal)
		var normal_impulse: float=contact.lambda/h
		var impulse: Vector3=(-tangent/maxf(contact.inverse_mass,0.000001)).limit_length(contact.friction*normal_impulse)
		var local_impulse: Vector3=pose.basis.inverse()*impulse
		for i: int in range(8): velocities[contact.binding[0][i]]+=local_impulse*contact.binding[1][i]*inv_masses[contact.binding[0][i]]
		contact_impulse_total+=normal_impulse
		contact_friction_impulse_total+=impulse.length()
		contact_point_total+=Vector3(contact.material)*normal_impulse
		contact_normal_total+=pose.basis.inverse()*Vector3(contact.normal)*normal_impulse
		active_time=maxf(active_time,3.0)

func _simulate(dt: float,state: PhysicsDirectBodyState3D=null) -> void:
	if state==null: return
	var pose: Transform3D=state.transform
	contact_cooldown=maxf(0,contact_cooldown-dt)
	contact_impulse_total=0
	contact_friction_impulse_total=0
	contact_point_total=Vector3.ZERO
	contact_normal_total=Vector3.ZERO
	contact_peak_speed=0
	var steps: int=4
	var h: float=dt/steps
	_prepare_beam_step(h)
	var inverse_basis: Basis=pose.basis.inverse()
	var local_linear: Vector3=inverse_basis*state.linear_velocity
	var local_angular: Vector3=inverse_basis*state.angular_velocity
	for i: int in range(nodes.size()): velocities[i]+=local_linear+local_angular.cross(nodes[i]-center)
	substep_old=PackedVector3Array()
	# Repair only an invalid initial placement before advancing dynamics.
	# This rigid translation creates neither local strain nor velocity.
	if initial_overlap_recovery:
		_gather_contacts(state,pose,pose,h,dt,true)
		for iteration: int in range(4):
			for contact: Dictionary in contacts:
				var point: Vector3=pose*_material_point(contact.binding,contact.offset)
				var depth: float=0.002-(point-Vector3(contact.plane)).dot(contact.normal)
				if depth>0: pose.origin+=Vector3(contact.normal)*depth
		initial_overlap_recovery=false
	var extra_force: Vector3=inverse_basis*(get_parent().applied_structure_force+get_parent().constant_force)-load_total
	var extra_torque: Vector3=inverse_basis*(get_parent().applied_structure_torque+get_parent().constant_torque)-load_torque
	var gravity: Vector3=inverse_basis*state.total_gravity
	for step: int in range(steps):
		var motion: Dictionary=_motion_of_nodes()
		var torque_acceleration: Vector3=Vector3.ZERO
		if motion.inertia.determinant()>0.00001: torque_acceleration=motion.inertia.inverse()*extra_torque
		var old: PackedVector3Array=nodes.duplicate()
		substep_old=old
		for i: int in range(nodes.size()):
			var arm: Vector3=nodes[i]-Vector3(motion.center)
			var rigid: Vector3=Vector3(motion.velocity)+Vector3(motion.omega).cross(arm)
			velocities[i]=Vector3(motion.velocity)*exp(-0.012*h)+Vector3(motion.omega).cross(arm)*exp(-0.18*h)+(velocities[i]-rigid)*exp(-3.8*h)
			velocities[i]+=(loads[i]*inv_masses[i]+gravity+extra_force/TOTAL_MASS+torque_acceleration.cross(arm))*h
			nodes[i]+=velocities[i]*h
		constraint_displacements.fill(Vector3.ZERO)
		_gather_contacts(state,pose,pose,h,dt if step==0 else h,true)
		beam_lambdas.fill(0.0)
		for iteration: int in range(8 if not contacts.is_empty() else 4):
			_solve_beams()
			_solve_contacts(state,pose,h)
		_update_plasticity(h)
		for i: int in range(nodes.size()):
			# Use the computed increments, avoiding subtraction of rounded
			# absolute positions when reconstructing constraint impulses.
			velocities[i]+=constraint_displacements[i]/h
			if not nodes[i].is_finite() or not velocities[i].is_finite():
				node_recovery_count+=1
				nodes[i]=old[i]
				velocities[i]=Vector3.ZERO
		_damp_beams()
		_contact_friction(pose,h)
	var motion: Dictionary=_motion_of_nodes()
	var x_axis: Vector3=Vector3.ZERO
	var z_axis: Vector3=Vector3.ZERO
	for z: int in range(2,5):
		for y: int in range(2): x_axis+=nodes[z*9+y*3+2]-nodes[z*9+y*3]
	for x: int in range(3):
		for y: int in range(2): z_axis+=nodes[4*9+y*3+x]-nodes[2*9+y*3+x]
	var fitted: Basis=Basis.IDENTITY
	if x_axis.is_finite() and z_axis.is_finite() and x_axis.length_squared()>0.000001 and x_axis.cross(z_axis).length_squared()>0.000001:
		x_axis=x_axis.normalized()
		z_axis=(z_axis-x_axis*z_axis.dot(x_axis)).normalized()
		var y_axis: Vector3=z_axis.cross(x_axis).normalized()
		fitted=Basis(x_axis,y_axis,x_axis.cross(y_axis))
	else: frame_recovery_count+=1
	var world_center: Vector3=pose*Vector3(motion.center)
	var final_basis: Basis=(pose.basis*fitted).orthonormalized()
	var final_linear: Vector3=pose.basis*Vector3(motion.velocity)
	var final_angular: Vector3=pose.basis*Vector3(motion.omega)
	for i: int in range(nodes.size()):
		var arm: Vector3=nodes[i]-Vector3(motion.center)
		nodes[i]=center+fitted.transposed()*arm
		velocities[i]=fitted.transposed()*(velocities[i]-Vector3(motion.velocity)-Vector3(motion.omega).cross(arm))
		maximum_displacement=maxf(maximum_displacement,nodes[i].distance_to(rest[i]))
	# Jolt advances the carrier's free pose after this callback. Set its
	# pre-advance pose so the final transform equals the solved nodal pose.
	var pre_basis: Basis=final_basis
	if final_angular.length()>0.000001: pre_basis=Basis(final_angular.normalized(),-final_angular.length()*dt)*final_basis
	state.transform=Transform3D(pre_basis,world_center-final_linear*dt-pre_basis*center)
	state.linear_velocity=final_linear
	state.angular_velocity=final_angular
	if contact_impulse_total>450 and contact_peak_speed>2.1 and contact_cooldown<=0:
		reporting_contact=true
		get_parent().emit_signal("collided",contact_point_total/contact_impulse_total,contact_normal_total.normalized(),contact_peak_speed)
		reporting_contact=false
		contact_cooldown=0.15
	_publish_beams()
	_clear_loads()
	_update_bones()
	get_parent().update_attachment_poses()

func _clear_loads() -> void:
	for i: int in range(loads.size()): loads[i]=Vector3.ZERO
	load_total=Vector3.ZERO
	load_torque=Vector3.ZERO

func _update_bones() -> void:
	for i: int in range(nodes.size()): skeleton.set_bone_pose_position(i,nodes[i])

func _update_meshes() -> void:
	_update_bones()
	if get_parent().has_method("update_collision_cage"): get_parent().update_collision_cage()

func displacement_at(point: Vector3) -> Vector3:
	var weights: Array=_weights(point)
	var displacement: Vector3=Vector3.ZERO
	for i: int in range(8): displacement+=(nodes[weights[0][i]]-rest[weights[0][i]])*weights[1][i]
	return displacement

func deformation_gradient(point: Vector3) -> Basis:
	# Exact derivative inside the material cell. A centered finite difference
	# at the outer wheel mounts would cross the interpolation clamp boundary.
	var xf: float=clampf((point.x+0.82)/0.82,0,2)
	var yf: float=clampf((point.y-0.42)/0.46,0,2)
	var xi: int=mini(int(xf),1)
	var yi: int=mini(int(yf),1)
	var zi: int=0
	while zi<5 and point.z>Z_STATIONS[zi+1]: zi+=1
	var tx: float=xf-xi
	var ty: float=yf-yi
	var dz: float=Z_STATIONS[zi+1]-Z_STATIONS[zi]
	var tz: float=clampf((point.z-Z_STATIONS[zi])/dz,0,1)
	var dx: Vector3=Vector3.ZERO
	var dy: Vector3=Vector3.ZERO
	var gradient_z: Vector3=Vector3.ZERO
	for z: int in range(2):
		for y: int in range(2):
			var base: int=(zi+z)*9+(yi+y)*3+xi
			dx+=(nodes[base+1]-nodes[base])*(ty if y else 1-ty)*(tz if z else 1-tz)/0.82
	for z: int in range(2):
		for x: int in range(2):
			var base: int=(zi+z)*9+yi*3+xi+x
			dy+=(nodes[base+3]-nodes[base])*(tx if x else 1-tx)*(tz if z else 1-tz)/0.46
	for y: int in range(2):
		for x: int in range(2):
			var base: int=zi*9+(yi+y)*3+xi+x
			gradient_z+=(nodes[base+9]-nodes[base])*(tx if x else 1-tx)*(ty if y else 1-ty)/dz
	return Basis(dx,dy,gradient_z)

func rotation_at(point: Vector3, fallback: Basis=Basis.IDENTITY) -> Basis:
	var result: Basis=deformation_gradient(point)
	if not result.is_finite() or result.determinant()<0.0001:
		alignment_recovery_count+=1
		return fallback
	# Polar decomposition isolates the attachment's rotation from its stretch.
	for iteration: int in range(6):
		var inverse_transpose: Basis=result.inverse().transposed()
		result=Basis((result.x+inverse_transpose.x)*0.5,(result.y+inverse_transpose.y)*0.5,(result.z+inverse_transpose.z)*0.5)
	if not result.is_finite() or result.determinant()<0.0001:
		alignment_recovery_count+=1
		return fallback
	return result.orthonormalized()

func attachment_strain(point: Vector3) -> Vector3:
	# Rigid movement of the cabin in the mass-centered cage does not bend a hub.
	var cabin_shift: Vector3=Vector3.ZERO
	for z: int in range(2,5):
		for y: int in range(2):
			for x: int in range(3):
				var index: int=z*9+y*3+x
				cabin_shift+=(nodes[index]-rest[index])/18.0
	return displacement_at(point)-cabin_shift

func reset_mesh() -> void:
	nodes=rest.duplicate()
	for i: int in range(velocities.size()): velocities[i]=Vector3.ZERO
	_clear_loads()
	beam_lengths=beam_originals.duplicate()
	beam_lambdas.fill(0.0)
	beam_broken.fill(0)
	_publish_beams()
	maximum_displacement=0
	broken_beams=0
	plastic_work=0
	plastic_energy=0
	contacts.clear()
	active_time=0
	shattered=false
	previous_world.clear()
	contact_cooldown=0
	initial_overlap_recovery=true
	frame_recovery_count=0
	node_recovery_count=0
	alignment_recovery_count=0
	unmapped_contact_count=0
	swept_sample_contact_count=0
	substep_old=PackedVector3Array()
	_update_bones()
