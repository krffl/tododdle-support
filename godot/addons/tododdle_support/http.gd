extends RefCounted
## Internal. Sends one HTTP request with [HTTPClient] and polls it every frame, so it works in
## every export (desktop, mobile and web) without a node in the scene tree.

## The outcome of one HTTP exchange.
class Response:
	extends RefCounted
	## The HTTP status, or 0 when no response came back.
	var status: int = 0
	## Response headers with lower-case names.
	var headers: Dictionary = {}
	var body: PackedByteArray = PackedByteArray()
	## Not empty when the request did not reach the server or no response came back.
	var network_error: String = ""

	func body_text() -> String:
		return body.get_string_from_utf8()


const _METHODS: Dictionary = {
	"GET": HTTPClient.METHOD_GET,
	"POST": HTTPClient.METHOD_POST,
	"PUT": HTTPClient.METHOD_PUT,
}

## How many times to poll per frame while a request or body is in flight.
const _POLLS_PER_FRAME: int = 8


## Sends [param method] to [param url]. Never fails with an error: problems come back in
## [member Response.network_error].
func request(
	method: String, url: String, headers: Dictionary, body: PackedByteArray, timeout_seconds: float
) -> Response:
	var response := Response.new()
	var target := _parse_url(url)
	if target.is_empty():
		response.network_error = "The URL is not valid: %s" % url
		return response
	if not _METHODS.has(method):
		response.network_error = "Unsupported method %s" % method
		return response

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		response.network_error = "No SceneTree to poll the request from."
		return response

	var deadline: int = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	var client := HTTPClient.new()
	var tls: TLSOptions = TLSOptions.client() if target["tls"] else null
	var err := client.connect_to_host(target["host"], target["port"], tls)
	if err != OK:
		response.network_error = "Could not start the connection (error %d)." % err
		return response

	while client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		if Time.get_ticks_msec() > deadline:
			client.close()
			response.network_error = "The connection timed out."
			return response
		await tree.process_frame
		client.poll()

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		response.network_error = _status_message(client.get_status())
		client.close()
		return response

	var header_lines := PackedStringArray()
	for name: Variant in headers:
		header_lines.append("%s: %s" % [str(name), str(headers[name])])
	err = client.request_raw(_METHODS[method], target["path"], header_lines, body)
	if err != OK:
		client.close()
		response.network_error = "Could not send the request (error %d)." % err
		return response

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			client.close()
			response.network_error = "The request timed out."
			return response
		for _i in _POLLS_PER_FRAME:
			client.poll()
			if client.get_status() != HTTPClient.STATUS_REQUESTING:
				break
		if client.get_status() == HTTPClient.STATUS_REQUESTING:
			await tree.process_frame

	if not client.has_response():
		response.network_error = _status_message(client.get_status())
		client.close()
		return response

	response.status = client.get_response_code()
	var raw_headers: Dictionary = client.get_response_headers_as_dictionary()
	for name: Variant in raw_headers:
		response.headers[str(name).to_lower()] = str(raw_headers[name]).strip_edges()

	while client.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			client.close()
			response.status = 0
			response.network_error = "Reading the response timed out."
			return response
		var got_data := false
		for _i in _POLLS_PER_FRAME:
			client.poll()
			var chunk := client.read_response_body_chunk()
			if chunk.is_empty():
				break
			got_data = true
			response.body.append_array(chunk)
			if client.get_status() != HTTPClient.STATUS_BODY:
				break
		if not got_data and client.get_status() == HTTPClient.STATUS_BODY:
			await tree.process_frame

	if client.get_status() in [HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
		response.status = 0
		response.network_error = _status_message(client.get_status())
	client.close()
	return response


## Splits [param url] into host, port, path and TLS. Returns an empty dictionary when it is not
## an http or https URL.
static func _parse_url(url: String) -> Dictionary:
	var scheme_end := url.find("://")
	if scheme_end < 0:
		return {}
	var scheme := url.substr(0, scheme_end).to_lower()
	if scheme != "http" and scheme != "https":
		return {}
	var tls := scheme == "https"
	var rest := url.substr(scheme_end + 3)
	var slash := rest.find("/")
	var authority := rest if slash < 0 else rest.substr(0, slash)
	var path := "/" if slash < 0 else rest.substr(slash)
	var fragment := path.find("#")
	if fragment >= 0:
		path = path.substr(0, fragment)
	var at := authority.rfind("@")
	if at >= 0:
		authority = authority.substr(at + 1)
	var host := authority
	var port := 443 if tls else 80
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			return {}
		host = authority.substr(1, close - 1)
		var after := authority.substr(close + 1)
		if after.begins_with(":"):
			if not after.substr(1).is_valid_int():
				return {}
			port = after.substr(1).to_int()
	else:
		var colon := authority.rfind(":")
		if colon >= 0:
			if not authority.substr(colon + 1).is_valid_int():
				return {}
			port = authority.substr(colon + 1).to_int()
			host = authority.substr(0, colon)
	if host.is_empty():
		return {}
	return {"host": host, "port": port, "path": path, "tls": tls}


static func _status_message(status: int) -> String:
	match status:
		HTTPClient.STATUS_CANT_RESOLVE:
			return "Could not resolve the host."
		HTTPClient.STATUS_CANT_CONNECT:
			return "Could not connect to the server."
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "The TLS handshake failed."
		HTTPClient.STATUS_CONNECTION_ERROR:
			return "The connection failed."
		HTTPClient.STATUS_DISCONNECTED:
			return "The connection closed before a response came back."
	return "The request failed (HTTP client status %d)." % status
