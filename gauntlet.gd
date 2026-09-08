extends Node

var game: Node3D
var active: bool=false
var scenario: String=""
var output: String=""
var elapsed: float=0.0
var sample_time: float=0.0
var duration: float=14
var samples: Array=[]
var frames: Array[float]=[]
var captures: Array[String]=[]
var peak_speed: float=0
var max_height: float=-1000
var min_up: float=1
var min_grounded: int=4
var seen_airborne: bool=false
var capture_index: int=0
var finished: bool=false
var wall_tick: int=0

func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--gauntlet="):
			scenario=arg.trim_prefix("--gauntlet=")
			active=true
		if arg.begins_with("--qa-output="):
			output=arg.trim_prefix("--qa-output=")
	if not active:
		set_process(false)
		set_physics_process(false)
		return
	if output=="":
		output=OS.get_user_data_dir().path_join("gauntlet")
	DirAccess.make_dir_recursive_absolute(output)
	match scenario:
		"straight","brake","reverse","steer","handbrake":
			game.vehicle.reset_car(Vector3(-100,0.15,85))
		"crash":
			game.vehicle.reset_car(Vector3(45,0.15,-2))
			duration=15
		"jump":
			game.vehicle.reset_car(Vector3(0,0.15,-15))
			duration=17
		"jump_clear":
			game.vehicle.reset_car(Vector3(0,0.15,15))
			duration=22
		"rollover":
			game.vehicle.reset_car(Vector3(5.55,0.15,-65))
			duration=15
		"bumps":
			game.vehicle.reset_car(Vector3(-35,0.15,10))
			duration=11
		"beauty":
			game.vehicle.reset_car(Vector3(0,0.15,15))
			game.orbit_yaw=0.52
			duration=6
		"cockpit":
			game.camera_mode=1
			duration=7
		"performance":
			game.vehicle.reset_car(Vector3(-100,0.15,85))
			duration=30
	game.camera_snap=true
	print("GAUNTLET_START ",scenario)

func _physics_process(dt: float) -> void:
	if finished:
		return
	elapsed+=dt
	var car: SimVehicle=game.vehicle
	car.throttle=0
	car.braking=0
	car.steering_input=0
	car.handbrake=false
	if elapsed>1.5:
		match scenario:
			"straight":
				car.throttle=1.0 if elapsed<10 else 0.0
			"brake":
				car.throttle=1.0 if elapsed<8 else 0.0
				car.braking=1.0 if elapsed>=8 else 0.0
			"reverse":
				car.throttle=-0.6 if elapsed<8 else 0.0
				car.braking=1.0 if elapsed>=8 else 0.0
			"steer":
				car.throttle=0.65
				car.steering_input=0.5 if elapsed>5 else 0.0
			"handbrake":
				car.throttle=0.8 if elapsed<7 else 0.0
				car.steering_input=0.75 if elapsed>7 and elapsed<9 else 0.0
				car.handbrake=elapsed>7 and elapsed<9
			"crash","jump","jump_clear","rollover":
				car.throttle=1 if car.damage<0.1 else 0.0
				if scenario=="jump_clear" and elapsed>13.5:
					car.throttle=0
					car.braking=1
				if scenario=="crash" and elapsed>9:
					game.orbit_yaw=lerpf(game.orbit_yaw,2.5,minf(dt*1.7,1))
			"bumps":
				car.throttle=0.45 if elapsed<7 else 0.0
			"cockpit":
				car.throttle=0.6
			"performance":
				car.throttle=0.6
				car.steering_input=0.4 if elapsed>6 else 0
	peak_speed=maxf(peak_speed,car.speed_kph)
	max_height=maxf(max_height,car.position.y)
	min_up=minf(min_up,car.global_basis.y.y)
	if elapsed>2:
		min_grounded=mini(min_grounded,car.grounded)
		if car.grounded==0:
			seen_airborne=true
	sample_time+=dt
	if sample_time>=0.1:
		sample_time=0
		var record: Dictionary=car.telemetry()
		record.time=elapsed
		record.mesh_displacement=car.deformer.maximum_displacement
		record.broken_beams=car.deformer.broken_beams
		samples.append(record)
	if elapsed>duration:
		finished=true
		call_deferred("_finish")

func _process(dt: float) -> void:
	var now: int=Time.get_ticks_usec()
	if elapsed>3 and wall_tick>0:
		frames.append(float(now-wall_tick)/1000.0)
	wall_tick=now
	if DisplayServer.get_name()=="headless" or scenario=="performance":
		return
	var times: Array[float]=[2.5,7.5,duration-0.5]
	if scenario=="beauty":
		times=[3.0]
	elif scenario=="jump":
		times=[2.5,6.5,8.5,10.0,11.7,11.9,12.1,14.0,16.5]
	elif scenario=="jump_clear":
		times=[3.0,9.0,12.0,13.1,13.3,13.7,14.4,16.0,21.5]
	elif scenario=="rollover":
		times=[3.0,5.5,8.0,10.5,13.5]
	elif scenario=="bumps":
		times=[2.5,4.0,5.5,7.0,10.5]
	if capture_index<times.size() and elapsed>=times[capture_index]:
		var index: int=capture_index
		capture_index+=1
		_capture(index)

func _capture(index: int) -> void:
	await RenderingServer.frame_post_draw
	var path: String=output.path_join("%s-%02d.png"%[scenario,index])
	var screenshot: Image=get_viewport().get_texture().get_image()
	if screenshot and not screenshot.is_empty():
		screenshot.save_png(path)
		captures.append(path)

func _finish() -> void:
	var ordered: Array[float]=frames.duplicate()
	ordered.sort()
	var p95: float=ordered[int(ordered.size()*0.95)] if ordered.size()>0 else 0
	var p99: float=ordered[int(ordered.size()*0.99)] if ordered.size()>0 else 0
	var avg: float=0
	for ms: float in frames:
		avg+=ms
	avg/=maxi(frames.size(),1)
	var result: Dictionary={"scenario":scenario,"duration_simulation_seconds":elapsed,"headless":DisplayServer.get_name()=="headless","peak_speed_kph":peak_speed,"max_height":max_height,"minimum_up_dot":min_up,"minimum_grounded":min_grounded,"airborne_observed":seen_airborne,"final":game.vehicle.telemetry(),"maximum_mesh_displacement":game.vehicle.deformer.maximum_displacement,"broken_beams":game.vehicle.deformer.broken_beams,"frame_count":frames.size(),"mean_frame_ms":avg,"p95_frame_ms":p95,"p99_frame_ms":p99,"wall_clock_fps":1000.0/maxf(avg,0.001),"captures":captures,"samples":samples}
	var file: FileAccess=FileAccess.open(output.path_join(scenario+".json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t"))
	file.close()
	result.erase("samples")
	print("GAUNTLET_RESULT ",JSON.stringify(result))
	get_tree().quit()
