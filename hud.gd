extends Control

var vehicle: SimVehicle
var slow: bool=false
var cockpit: bool=false
var age: float=0
var notice: String=""
var notice_time: float=0
var fps_visible: bool=false
var font: Font=ThemeDB.fallback_font
var hint_style: StyleBoxFlat

func _ready() -> void:
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hint_style=_badge()

func _process(delta: float) -> void:
	age+=delta
	notice_time=maxf(0,notice_time-delta)
	queue_redraw()

func show_notice(text: String) -> void:
	notice=text
	notice_time=2.2

func _draw() -> void:
	if vehicle==null:
		return
	var screen: Vector2=get_viewport_rect().size
	var center: Vector2=Vector2(screen.x-128,screen.y-125)
	var white: Color=Color(0.97,0.98,1,0.92)
	var dim: Color=Color(0.95,0.97,1,0.9)
	var orange: Color=Color(1.0,0.41,0.12)
	var gear_text: String="R" if vehicle.gear<0 else str(vehicle.gear)
	if not cockpit:
		draw_circle(center,91,Color(0.025,0.033,0.042,0.66))
		draw_arc(center,87,deg_to_rad(135),deg_to_rad(405),72,Color(0.85,0.88,0.9,0.18),2,true)
		draw_arc(center,86,deg_to_rad(135),deg_to_rad(135+270*vehicle.rpm/7000.0),72,orange,3,true)
		for tick: int in range(8):
			var theta: float=deg_to_rad(135+270*tick/7.0)
			var direction: Vector2=Vector2(cos(theta),sin(theta))
			draw_line(center+direction*75,center+direction*82,white if tick<6 else orange,1.2,true)
			var text_pos: Vector2=center+direction*64+Vector2(-4,4)
			draw_string(font,text_pos,str(tick),HORIZONTAL_ALIGNMENT_LEFT,-1,14,dim)
		var speed_text: String=str(roundi(vehicle.speed_kph))
		var width: float=font.get_string_size(speed_text,HORIZONTAL_ALIGNMENT_LEFT,-1,43).x
		draw_string(font,center+Vector2(-width/2,8),speed_text,HORIZONTAL_ALIGNMENT_LEFT,-1,43,white)
		draw_string(font,center+Vector2(-15,29),"km/h",HORIZONTAL_ALIGNMENT_LEFT,-1,13,dim)
		draw_string(font,center+Vector2(-7,59),gear_text,HORIZONTAL_ALIGNMENT_LEFT,-1,21,orange)
		var rpm_label: String="x1000 RPM"
		var rpm_width: float=font.get_string_size(rpm_label,HORIZONTAL_ALIGNMENT_LEFT,-1,11).x
		draw_string(font,center+Vector2(-rpm_width/2,79),rpm_label,HORIZONTAL_ALIGNMENT_LEFT,-1,11,dim)
		if vehicle.handbrake:
			draw_string(font,center+Vector2(-14,-31),"(P)",HORIZONTAL_ALIGNMENT_LEFT,-1,15,orange)
	else:
		var badge_width: float=76 if vehicle.handbrake else 40
		draw_style_box(hint_style,Rect2(screen.x-18-badge_width,screen.y-50,badge_width,34))
		var gear_width: float=font.get_string_size(gear_text,HORIZONTAL_ALIGNMENT_LEFT,-1,21).x
		var compact: Vector2=Vector2(screen.x-38-gear_width/2,screen.y-26)
		draw_string(font,compact,gear_text,HORIZONTAL_ALIGNMENT_LEFT,-1,21,orange)
		if vehicle.handbrake:
			draw_string(font,Vector2(screen.x-84,screen.y-28),"(P)",HORIZONTAL_ALIGNMENT_LEFT,-1,15,orange)
	if vehicle.damage>0.04:
		var col: Color=orange if vehicle.damage<0.6 else Color(1,0.19,0.12)
		draw_string(font,Vector2(screen.x-198,screen.y-19),"VEHICLE DAMAGE  %d%%"%roundi(vehicle.damage*100),HORIZONTAL_ALIGNMENT_LEFT,-1,11,col)
	var hint: String="WASD  drive    SPACE  handbrake    R  reset    TAB  camera    J  slow motion    ESC  pause"
	var hint_width: float=font.get_string_size(hint,HORIZONTAL_ALIGNMENT_LEFT,-1,16).x
	draw_style_box(hint_style,Rect2(18,screen.y-50,hint_width+24,34))
	draw_string(font,Vector2(30,screen.y-27),hint,HORIZONTAL_ALIGNMENT_LEFT,-1,16,white)
	if slow:
		draw_style_box(_badge(),Rect2(25,24,118,30))
		draw_string(font,Vector2(38,44),"⅛  SLOW MOTION",HORIZONTAL_ALIGNMENT_LEFT,-1,12,white)
	if notice_time>0:
		var w: float=font.get_string_size(notice,HORIZONTAL_ALIGNMENT_LEFT,-1,15).x
		draw_string_outline(font,Vector2((screen.x-w)/2,screen.y-65),notice,HORIZONTAL_ALIGNMENT_LEFT,-1,15,3,Color(0,0,0,0.6))
		draw_string(font,Vector2((screen.x-w)/2,screen.y-65),notice,HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color(1,1,1,minf(notice_time,1)))
	if fps_visible:
		draw_string(font,Vector2(screen.x-82,26),"%d FPS"%Engine.get_frames_per_second(),HORIZONTAL_ALIGNMENT_LEFT,-1,12,white)

func _badge() -> StyleBoxFlat:
	var style: StyleBoxFlat=StyleBoxFlat.new()
	style.bg_color=Color(0.04,0.05,0.06,0.7)
	style.corner_radius_top_left=3
	style.corner_radius_top_right=3
	style.corner_radius_bottom_left=3
	style.corner_radius_bottom_right=3
	return style
