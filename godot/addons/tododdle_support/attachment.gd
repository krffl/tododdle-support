class_name TododdleSupportAttachment
extends RefCounted
## A file the game hands over with a report: raw bytes, a file name and a content type.
##
## Nothing is collected automatically. Use the helpers to make the two common attachments:
## [method from_viewport] for a screenshot and [method from_text_file] for a log.

## The contract's per-file limit (10 MB).
const MAX_BYTES := 10485760
## Content types the contract allows.
const CONTENT_TYPES: PackedStringArray = [
	"image/png", "image/jpeg", "image/webp", "image/gif", "application/pdf", "text/plain"
]

var bytes: PackedByteArray = PackedByteArray()
## Shown on the ticket. 1 to 255 characters.
var file_name: String = ""
## One of [constant CONTENT_TYPES].
var content_type: String = ""


func _init(
	p_bytes: PackedByteArray = PackedByteArray(), p_file_name: String = "", p_content_type: String = ""
) -> void:
	bytes = p_bytes
	file_name = p_file_name
	content_type = p_content_type


## The size in bytes.
func get_size() -> int:
	return bytes.size()


## Whether this is an image the dialog can preview.
func is_image() -> bool:
	return content_type.begins_with("image/")


## Whether this is plain text.
func is_text() -> bool:
	return content_type == "text/plain"


## A PNG of [param image]. If the PNG is over [param max_bytes], the image is scaled down by half
## until it fits. Returns null when [param image] is null or empty.
static func from_image(
	image: Image, file_name: String = "screenshot.png", max_bytes: int = MAX_BYTES
) -> TododdleSupportAttachment:
	if image == null or image.is_empty():
		return null
	var copy := image.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	var png := copy.save_png_to_buffer()
	while png.size() > max_bytes and copy.get_width() > 16 and copy.get_height() > 16:
		copy.resize(maxi(copy.get_width() / 2, 1), maxi(copy.get_height() / 2, 1), Image.INTERPOLATE_BILINEAR)
		png = copy.save_png_to_buffer()
	if png.is_empty() or png.size() > max_bytes:
		return null
	return TododdleSupportAttachment.new(png, file_name, "image/png")


## A PNG screenshot of [param viewport], usually [code]get_viewport()[/code]. Call it before you
## open the dialog so the dialog is not in the picture. Returns null when the viewport has no
## image (for example in a headless run).
static func from_viewport(
	viewport: Viewport, file_name: String = "screenshot.png", max_bytes: int = MAX_BYTES
) -> TododdleSupportAttachment:
	if viewport == null or DisplayServer.get_name() == "headless":
		return null
	var texture := viewport.get_texture()
	if texture == null:
		return null
	return from_image(texture.get_image(), file_name, max_bytes)


## A [code]text/plain[/code] attachment from the file at [param path], for example
## [code]user://hitch_log.txt[/code]. If the file is over [param max_bytes], only its end (the
## newest lines) is kept. Returns null when the file is missing or empty.
static func from_text_file(
	path: String, file_name: String = "", max_bytes: int = MAX_BYTES
) -> TododdleSupportAttachment:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var length := file.get_length()
	if length > max_bytes:
		file.seek(length - max_bytes)
	var data := file.get_buffer(mini(length, max_bytes))
	file.close()
	var name := file_name if not file_name.is_empty() else path.get_file()
	return _text_attachment(data, name, length > max_bytes)


## A [code]text/plain[/code] attachment from [param text]. If it is over [param max_bytes] in
## UTF-8, only its end is kept. Returns null when [param text] is empty.
static func from_text(
	text: String, file_name: String = "log.txt", max_bytes: int = MAX_BYTES
) -> TododdleSupportAttachment:
	var data := text.to_utf8_buffer()
	var trimmed := data.size() > max_bytes
	if trimmed:
		data = data.slice(data.size() - max_bytes)
	return _text_attachment(data, file_name, trimmed)


static func _text_attachment(data: PackedByteArray, name: String, trimmed: bool) -> TododdleSupportAttachment:
	if trimmed:
		# Do not start in the middle of a UTF-8 character.
		var start := 0
		while start < data.size() and start < 4 and (data[start] & 0xC0) == 0x80:
			start += 1
		data = data.slice(start)
	if data.is_empty():
		return null
	if name.is_empty():
		name = "log.txt"
	return TododdleSupportAttachment.new(data, name.left(255), "text/plain")
