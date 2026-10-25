# test_capability_grant.gd —— CapabilityGrant 测试（文档 23 号 §14.14）
extends GutTest


func test_sensitive() -> void:
	assert_true(CapabilityGrant.is_sensitive(Capability.UI_INJECT), "ui.inject 是敏感能力")
	assert_false(CapabilityGrant.is_sensitive(Capability.BOARD_READ), "board.read 非敏感")


func test_grant_revoke() -> void:
	var g := CapabilityGrant.new()
	assert_false(g.is_granted(Capability.UI_INJECT), "敏感能力默认未授权")
	g.grant(Capability.UI_INJECT)
	assert_true(g.is_granted(Capability.UI_INJECT), "授权后可用")
	g.revoke(Capability.UI_INJECT)
	assert_false(g.is_granted(Capability.UI_INJECT), "撤销后不可用")


func test_non_sensitive_default() -> void:
	var g := CapabilityGrant.new()
	assert_true(g.is_granted(Capability.BOARD_READ), "非敏感能力默认可用")


func test_pending() -> void:
	var g := CapabilityGrant.new()
	assert_true(g.is_pending(Capability.NET_WORKSHOP), "未处理前是待授权")
	g.grant(Capability.NET_WORKSHOP)
	assert_false(g.is_pending(Capability.NET_WORKSHOP), "授权后不再待授权")


func test_snapshot_restore() -> void:
	var g := CapabilityGrant.new()
	g.grant(Capability.UI_INJECT)
	var snap := g.snapshot()
	var g2 := CapabilityGrant.new()
	g2.restore(snap)
	assert_true(g2.is_granted(Capability.UI_INJECT), "restore 应恢复授权记录")
