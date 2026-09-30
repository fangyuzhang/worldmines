extends SceneTree
func _initialize():
    var theme = load("res://assets/generated/ui-kit/cozy_toys/cozy_toys_theme.tres") as Theme
    if theme == null:
        push_error("UI consumer could not load Theme")
        quit(1)
        return
    var controls = [Button.new(), Panel.new(), PanelContainer.new(), LineEdit.new(), TextEdit.new(), ProgressBar.new(), TabBar.new(), TabContainer.new(), CheckBox.new(), CheckButton.new(), HSlider.new(), VSlider.new(), HScrollBar.new(), VScrollBar.new(), OptionButton.new()]
    for control in controls:
        control.theme = theme
        root.add_child(control)
        for target_size in [Vector2(240, 72), Vector2(520, 240)]:
            control.custom_minimum_size = target_size
            control.size = target_size
        root.remove_child(control)
        control.free()
    print("UI_CARD_CONSUMER_SMOKE_OK")
    quit()
