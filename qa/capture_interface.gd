extends SceneTree
var out := ""
func _initialize() -> void:
 for arg in OS.get_cmdline_user_args():
  if arg.begins_with("--qa-out="): out=arg.trim_prefix("--qa-out=")
 call_deferred("capture")
func capture() -> void:
 if out.is_empty() or DisplayServer.get_name()=="headless": quit(2); return
 DirAccess.make_dir_recursive_absolute(out)
 var game = load("res://main.tscn").instantiate()
 root.add_child(game)
 for i in range(100): await process_frame
 await RenderingServer.frame_post_draw
 root.get_texture().get_image().save_png(out+"/vehicle-hud.png")
 Input.action_press("handbrake")
 for i in range(5): await process_frame
 await RenderingServer.frame_post_draw
 root.get_texture().get_image().save_png(out+"/vehicle-parking-brake.png")
 Input.action_release("handbrake")
 game.set_paused(true)
 for i in range(5): await process_frame
 await RenderingServer.frame_post_draw
 root.get_texture().get_image().save_png(out+"/vehicle-menu.png")
 for button in game.pause_panel.find_children("*","Button",true,false):
  assert(root.get_visible_rect().encloses(button.get_global_rect()))
 game.set_paused(false)
 game.camera_mode=1
 game.camera_snap=true
 for i in range(20): await process_frame
 await RenderingServer.frame_post_draw
 root.get_texture().get_image().save_png(out+"/vehicle-cockpit.png")
 print("INTERFACE_CAPTURE_PASS")
 quit()
