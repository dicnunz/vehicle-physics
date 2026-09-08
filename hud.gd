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
	var white := Color("f1f0e8")
	var dim := Color("aaafa9")
	var orange := Color("e8b65b")
	var gear_text := "R" if vehicle.gear < 0 else str(vehicle.gear)
	var left := screen.x - 264.0
	var top := screen.y - 138.0
	if not cockpit:
		draw_style_box(hint_style, Rect2(left, top, 240, 112))
		draw_string(font, Vector2(left + 17, top + 21), "RPM  %d" % roundi(vehicle.rpm), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, dim)
		draw_string(font, Vector2(left + 17, top + 69), str(roundi(vehicle.speed_kph)), HORIZONTAL_ALIGNMENT_LEFT, -1, 43, white)
		draw_string(font, Vector2(left + 113, top + 68), "km/h", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, dim)
		draw_line(Vector2(left + 166, top + 20), Vector2(left + 166, top + 73), Color(1,1,1,.15))
		draw_string(font, Vector2(left + 194, top + 59), gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, orange)
		draw_string(font, Vector2(left + 187, top + 75), "GEAR", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, dim)
		for tick in range(28):
			var active := float(tick) / 28.0 < clampf(vehicle.rpm / 7000.0, 0.0, 1.0)
			var color := (Color("e16a50") if tick > 23 else orange) if active else Color(1,1,1,.12)
			draw_rect(Rect2(left + 17 + tick * 7.4, top + 91, 5, 5), color)
	else:
		draw_style_box(hint_style, Rect2(screen.x - 76, screen.y - 72, 52, 46))
		draw_string(font, Vector2(screen.x - 59, screen.y - 40), gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, orange)
	if vehicle.handbrake:
		draw_string(font, Vector2(left + 17, top - 12), "PARKING BRAKE", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, orange)
	if vehicle.damage > 0.04:
		var color := orange if vehicle.damage < 0.6 else Color("e16a50")
		draw_string(font, Vector2(left + 17, top - 30), "DAMAGE  %d%%" % roundi(vehicle.damage * 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)
	var hint := "WASD  Drive    SPACE  Brake    TAB  Camera" if age < 12.0 else "ESC  Menu"
	var hint_width := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	draw_style_box(hint_style, Rect2(24, screen.y - 59, hint_width + 28, 33))
	draw_string(font, Vector2(38, screen.y - 38), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, white)
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
	style.bg_color=Color(0.035,0.045,0.043,0.9)
	style.corner_radius_top_left=3
	style.corner_radius_top_right=3
	style.corner_radius_bottom_left=3
	style.corner_radius_bottom_right=3
	return style
