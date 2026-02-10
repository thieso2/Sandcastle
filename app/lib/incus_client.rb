require "net_http_unix"
require "json"
require "uri"

class IncusClient
  class Error < StandardError; end
  class NotFoundError < Error; end
  class OperationError < Error; end

  OPERATION_TIMEOUT = 30

  def initialize(socket: nil)
    @socket = socket || ENV.fetch("INCUS_SOCKET", "/var/lib/incus/unix.socket")
  end

  # -- Instances --

  def create_instance(name:, source:, config: {}, devices: {}, profiles: ["default"], type: "container")
    body = {
      name: name,
      source: source,
      config: config,
      devices: devices,
      profiles: profiles,
      type: type
    }
    resp = post("/1.0/instances", body)
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  def get_instance(name)
    get("/1.0/instances/#{name}")["metadata"]
  end

  def delete_instance(name)
    resp = delete("/1.0/instances/#{name}")
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  def change_state(name, action:, force: false, timeout: 30)
    body = { action: action, timeout: timeout, force: force }
    resp = put("/1.0/instances/#{name}/state", body)
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  def get_instance_state(name)
    get("/1.0/instances/#{name}/state")["metadata"]
  end

  def update_instance(name, config: nil, devices: nil)
    current = get_instance(name)
    body = {}
    body["config"] = config if config
    body["devices"] = devices || current["devices"] || {}
    body["config"] = config || current["config"] || {}

    # PATCH merges, so only send what we want to change
    patch_body = {}
    patch_body["config"] = config if config
    patch_body["devices"] = devices if devices
    resp = patch("/1.0/instances/#{name}", patch_body)
    wait_for_operation(resp) if resp.is_a?(Hash) && resp["type"] == "async"
    resp
  end

  # -- Exec --

  def exec(name, command:, environment: {}, wait_for_websocket: false)
    body = {
      command: command,
      environment: environment,
      "wait-for-websocket": false,
      "record-output": true,
      interactive: false
    }
    resp = post("/1.0/instances/#{name}/exec", body)
    op = wait_for_operation(resp)

    metadata = op.dig("metadata", "metadata") || op["metadata"] || {}
    output = metadata.dig("output") || {}
    stdout_url = output["1"]
    stderr_url = output["2"]

    stdout = stdout_url ? fetch_log(stdout_url) : ""
    stderr = stderr_url ? fetch_log(stderr_url) : ""
    exit_code = metadata.dig("return") || metadata.dig("exit_code") || 0

    { stdout: stdout, stderr: stderr, exit_code: exit_code }
  end

  # -- Files --

  def push_file(name, path:, content:, mode: "0644", uid: 0, gid: 0)
    headers = {
      "Content-Type" => "application/octet-stream",
      "X-Incus-mode" => mode,
      "X-Incus-uid" => uid.to_s,
      "X-Incus-gid" => gid.to_s
    }
    raw_request("POST", "/1.0/instances/#{name}/files?path=#{URI.encode_uri_component(path)}", content, headers)
  end

  # -- Snapshots --

  def create_snapshot(name, snapshot_name:, stateful: false)
    body = { name: snapshot_name, stateful: stateful }
    resp = post("/1.0/instances/#{name}/snapshots", body)
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  def list_snapshots(name)
    resp = get("/1.0/instances/#{name}/snapshots?recursion=1")
    resp["metadata"] || []
  end

  def get_snapshot(name, snapshot_name)
    get("/1.0/instances/#{name}/snapshots/#{snapshot_name}")["metadata"]
  end

  def delete_snapshot(name, snapshot_name)
    resp = delete("/1.0/instances/#{name}/snapshots/#{snapshot_name}")
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  def restore_snapshot(name, snapshot_name)
    body = { restore: snapshot_name }
    resp = put("/1.0/instances/#{name}", body)
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  # -- Copy (ZFS clone) --

  def copy_instance(source_name, target_name, snapshot_name: nil, profiles: nil)
    source_spec = { type: "copy", source: source_name }
    source_spec[:source] = "#{source_name}/#{snapshot_name}" if snapshot_name

    body = {
      name: target_name,
      source: {
        type: "copy",
        source: source_name
      }
    }
    body[:source][:source] = "#{source_name}/#{snapshot_name}" if snapshot_name
    body[:profiles] = profiles if profiles

    resp = post("/1.0/instances", body)
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  def rename_instance(name, new_name)
    body = { name: new_name }
    resp = post("/1.0/instances/#{name}", body)
    wait_for_operation(resp) if resp["type"] == "async"
    resp
  end

  # -- Networks --

  def create_network(name, config: {})
    body = { name: name, type: "bridge", config: config }
    post("/1.0/networks", body)
  end

  def get_network(name)
    get("/1.0/networks/#{name}")["metadata"]
  end

  def delete_network(name)
    delete("/1.0/networks/#{name}")
  end

  # -- Devices (via instance PATCH) --

  def add_device(name, device_name, device_config)
    instance = get_instance(name)
    devices = instance["devices"] || {}
    devices[device_name] = device_config
    update_instance(name, devices: devices)
  end

  def remove_device(name, device_name)
    instance = get_instance(name)
    devices = instance["devices"] || {}
    devices.delete(device_name)
    update_instance(name, devices: devices)
  end

  # -- Server --

  def server_info
    get("/1.0")["metadata"]
  end

  private

  def fetch_log(log_path)
    # log_path is like /1.0/instances/<name>/logs/<file>
    resp = get(log_path)
    # Log endpoints return raw text, not JSON metadata
    resp.is_a?(String) ? resp : (resp["metadata"] || "").to_s
  rescue Error
    ""
  end

  def get(path)
    request("GET", path)
  end

  def post(path, body = nil)
    request("POST", path, body)
  end

  def put(path, body = nil)
    request("PUT", path, body)
  end

  def patch(path, body = nil)
    request("PATCH", path, body)
  end

  def delete(path)
    request("DELETE", path)
  end

  def request(method, path, body = nil)
    client = NetX::HTTPUnix.new("unix://#{@socket}")
    client.read_timeout = OPERATION_TIMEOUT + 10

    req = case method
    when "GET"    then Net::HTTP::Get.new(path)
    when "POST"   then Net::HTTP::Post.new(path)
    when "PUT"    then Net::HTTP::Put.new(path)
    when "PATCH"  then Net::HTTP::Patch.new(path)
    when "DELETE" then Net::HTTP::Delete.new(path)
    end

    req["Content-Type"] = "application/json"
    req.body = body.to_json if body

    response = client.request(req)
    handle_response(response)
  end

  def raw_request(method, path, body, headers = {})
    client = NetX::HTTPUnix.new("unix://#{@socket}")
    client.read_timeout = OPERATION_TIMEOUT + 10

    req = case method
    when "POST" then Net::HTTP::Post.new(path)
    when "PUT"  then Net::HTTP::Put.new(path)
    end

    headers.each { |k, v| req[k] = v }
    req.body = body

    response = client.request(req)
    handle_response(response)
  end

  def handle_response(response)
    case response.code.to_i
    when 200..299
      begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        response.body
      end
    when 202
      JSON.parse(response.body)
    when 404
      raise NotFoundError, parse_error(response)
    else
      raise Error, "Incus API error (#{response.code}): #{parse_error(response)}"
    end
  end

  def parse_error(response)
    data = JSON.parse(response.body)
    data["error"] || data["metadata"]&.to_s || response.body
  rescue JSON::ParserError
    response.body
  end

  def wait_for_operation(response)
    op_url = response.dig("operation")
    return response unless op_url

    uuid = op_url.split("/").last
    get("/1.0/operations/#{uuid}/wait?timeout=#{OPERATION_TIMEOUT}")
  end
end
