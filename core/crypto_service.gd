# crypto_service.gd —— 薄封装 Godot 内置加密 API（文档 §2.1 决策表）
# AES-256 / SHA-256 / DEFLATE / base64，全部走内置能力，零外部依赖。
# 注：Godot 4 中 AES 走独立 AESContext 类（非 Crypto.KEY_AES，那是 Godot 3 旧 API）。
class_name CryptoService
extends RefCounted


## SHA-256 摘要，返回十六进制字符串。
func sha256_bytes(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()


func sha256_text(text: String) -> String:
	return sha256_bytes(text.to_utf8_buffer())


## AES-256 加密（CBC 模式，IV 由密钥派生，拼接在密文头部）。
func aes_encrypt(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var iv := _derive_iv(key)
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_ENCRYPT, _pad_key(key), iv)
	var cipher := ctx.update(_pkcs7_pad(data))
	ctx.finish()
	var out := PackedByteArray()
	out.append_array(iv)
	out.append_array(cipher)
	return out


## AES-256 解密，读取密文头部 16 字节作为 IV。
func aes_decrypt(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var iv := data.slice(0, 16)
	var cipher := data.slice(16, data.size())
	var ctx := AESContext.new()
	ctx.start(AESContext.MODE_CBC_DECRYPT, _pad_key(key), iv)
	var padded := ctx.update(cipher)
	ctx.finish()
	return _pkcs7_unpad(padded)


## DEFLATE 压缩 / 解压。
func compress(data: PackedByteArray) -> PackedByteArray:
	return data.compress(FileAccess.COMPRESSION_DEFLATE)


func decompress(data: PackedByteArray, expected_size: int = 0) -> PackedByteArray:
	return data.decompress(expected_size, FileAccess.COMPRESSION_DEFLATE)


func base64_encode(data: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(data)


func base64_decode(s: String) -> PackedByteArray:
	return Marshalls.base64_to_raw(s)


## 密钥必须是 32 字节（AES-256）；不足则补零，超长则截断。
func _pad_key(key: PackedByteArray) -> PackedByteArray:
	var k := key.duplicate()
	k.resize(32)
	return k


## IV 由密钥 SHA-256 前 16 字节派生（确定性场景下足够）。
func _derive_iv(key: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(_pad_key(key))
	return ctx.finish().slice(0, 16)


## PKCS#7 填充，使明文长度为 16 的倍数。
func _pkcs7_pad(data: PackedByteArray) -> PackedByteArray:
	var out := data.duplicate()
	var pad := 16 - (out.size() % 16)
	for i in pad:
		out.append(pad)
	return out


func _pkcs7_unpad(data: PackedByteArray) -> PackedByteArray:
	if data.is_empty():
		return data
	var pad := data[data.size() - 1]
	if pad < 1 or pad > 16 or pad > data.size():
		return data
	return data.slice(0, data.size() - pad)
