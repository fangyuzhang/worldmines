# crypto_service.gd —— 薄封装 Godot 内置加密 API（文档 §2.1 决策表）
# AES-256 / SHA-256 / DEFLATE / base64，全部走内置能力，零外部依赖。
class_name CryptoService
extends RefCounted

var _crypto := Crypto.new()


## SHA-256 摘要，返回十六进制字符串。
func sha256_bytes(data: PackedByteArray) -> String:
	return _crypto.hash(HashingContext.HASH_SHA256, data).hex_encode()


func sha256_text(text: String) -> String:
	return sha256_bytes(text.to_utf8_buffer())


## AES-256 加密（CBC 模式 + 随机 IV，IV 拼接在密文头部）。
func aes_encrypt(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var iv := _random_iv(key)
	var cipher := _crypto.encrypt(Crypto.KEY_AES, key, iv, data)
	var out := PackedByteArray()
	out.append_array(iv)
	out.append_array(cipher)
	return out


## AES-256 解密，读取密文头部 16 字节作为 IV。
func aes_decrypt(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var iv := data.slice(0, 16)
	var cipher := data.slice(16, data.size())
	return _crypto.decrypt(Crypto.KEY_AES, key, iv, cipher)


## DEFLATE 压缩 / 解压。
func compress(data: PackedByteArray) -> PackedByteArray:
	return data.compress(FileAccess.COMPRESSION_DEFLATE)


func decompress(data: PackedByteArray, expected_size: int = 0) -> PackedByteArray:
	return data.decompress(expected_size, FileAccess.COMPRESSION_DEFLATE)


func base64_encode(data: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(data)


func base64_decode(s: String) -> PackedByteArray:
	return Marshalls.base64_to_raw(s)


func _random_iv(key: PackedByteArray) -> PackedByteArray:
	# IV 由密钥派生（确定性场景下足够），16 字节。
	var h := _crypto.hash(HashingContext.HASH_SHA256, key)
	return h.slice(0, 16)
