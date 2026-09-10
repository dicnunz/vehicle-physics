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
	var interface_font := SystemFont.new()
	interface_font.font_names = PackedStringArray(["Helvetica Neue", "Arial"])
	font = interface_font
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
	var dim := Color("becbd7")
	var orange := Color("89c5f2")
	var gear_text := "R" if vehicle.gear < 0 else str(vehicle.gear)
	var left := screen.x - 304.0
	var top := screen.y - 158.0
	if not cockpit:
		draw_style_box(hint_style, Rect2(left, top, 280, 132))
		draw_string(font, Vector2(left + 17, top + 21), "%d rpm" % roundi(vehicle.rpm), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, dim)
		draw_string(font, Vector2(left + 17, top + 78), str(roundi(vehicle.speed_kph)), HORIZONTAL_ALIGNMENT_LEFT, -1, 52, white)
		draw_string(font, Vector2(left + 125, top + 76), "km/h", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, dim)
		draw_line(Vector2(left + 195, top + 20), Vector2(left + 195, top + 73), Color(1,1,1,.15))
		draw_string(font, Vector2(left + 225, top + 65), gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, orange)
		draw_string(font, Vector2(left + 218, top + 88), "Gear", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, dim)
		for tick in range(28):
			var active := float(tick) / 28.0 < clampf(vehicle.rpm / 7000.0, 0.0, 1.0)
			var color := (Color("e16a50") if tick > 23 else orange) if active else Color(1,1,1,.12)
			draw_rect(Rect2(left + 17 + tick * 8.6, top + 108, 6, 4), color)
	else:
		draw_style_box(hint_style, Rect2(screen.x - 76, screen.y - 72, 52, 46))
		draw_string(font, Vector2(screen.x - 59, screen.y - 40), gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, orange)
	var status_y := top - 40.0
	if vehicle.handbrake:
		_draw_status("Parking brake", left, status_y, orange)
		status_y -= 38.0
	if vehicle.damage > 0.04:
		var color := orange if vehicle.damage < 0.6 else Color("ffae97")
		_draw_status("Damage  %d%%" % roundi(vehicle.damage * 100), left, status_y, color)
	var hint := "WASD  Drive    SPACE  Handbrake    TAB  Camera" if age < 12.0 else "ESC  Menu"
	var hint_width := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	draw_style_box(hint_style, Rect2(24, screen.y - 59, hint_width + 28, 33))
	draw_string(font, Vector2(38, screen.y - 38), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, white)
	if slow:
		draw_style_box(_badge(),Rect2(25,24,118,30))
		draw_string(font,Vector2(38,44),"⅛  Slow motion",HORIZONTAL_ALIGNMENT_LEFT,-1,12,white)
	if notice_time>0:
		var w: float=font.get_string_size(notice,HORIZONTAL_ALIGNMENT_LEFT,-1,15).x
		draw_string_outline(font,Vector2((screen.x-w)/2,screen.y-65),notice,HORIZONTAL_ALIGNMENT_LEFT,-1,15,3,Color(0,0,0,0.6))
		draw_string(font,Vector2((screen.x-w)/2,screen.y-65),notice,HORIZONTAL_ALIGNMENT_LEFT,-1,15,Color(1,1,1,minf(notice_time,1)))
	if fps_visible:
		draw_string(font,Vector2(screen.x-82,26),"%d FPS"%Engine.get_frames_per_second(),HORIZONTAL_ALIGNMENT_LEFT,-1,12,white)

func _draw_status(text: String, left: float, top: float, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 28.0
	draw_style_box(hint_style, Rect2(left, top, width, 32))
	draw_string(font, Vector2(left + 14, top + 22), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, color)

func _badge() -> StyleBoxFlat:
	var style: StyleBoxFlat=StyleBoxFlat.new()
	style.bg_color=Color(0.06,0.085,0.12,0.94)
	style.corner_radius_top_left=12
	style.corner_radius_top_right=12
	style.corner_radius_bottom_left=12
	style.corner_radius_bottom_right=12
	return style
