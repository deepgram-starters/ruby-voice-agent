# Ruby Voice Agent Starter - Backend Server
#
# Simple WebSocket proxy to Deepgram's Voice Agent API.
# Forwards all messages (JSON and binary) bidirectionally between client and Deepgram.
#
# Routes:
#   GET  /api/session       - Issue signed session token
#   GET  /api/metadata      - Project metadata from deepgram.toml
#   GET  /health            - Health check endpoint
#   WS   /api/voice-agent   - WebSocket proxy to Deepgram Agent API (auth required)

require "sinatra"
require "sinatra/cross_origin"
require "faye/websocket"
require "json"
require "toml-rb"
require "dotenv"
require "jwt"
require "securerandom"

# Load .env file if present
Dotenv.load if File.exist?(".env")

# ============================================================================
# CONFIGURATION
# ============================================================================

# Validate required environment variables
unless ENV["DEEPGRAM_API_KEY"]
  abort "ERROR: DEEPGRAM_API_KEY environment variable is required\n" \
        "Please copy sample.env to .env and add your API key"
end

DEEPGRAM_API_KEY    = ENV["DEEPGRAM_API_KEY"]
DEEPGRAM_AGENT_URL  = "wss://agent.deepgram.com/v1/agent/converse"
PORT                = (ENV["PORT"] || "8081").to_i
HOST                = ENV["HOST"] || "0.0.0.0"
SESSION_SECRET      = ENV["SESSION_SECRET"] || SecureRandom.hex(32)
JWT_EXPIRY          = 3600 # 1 hour in seconds

# Reserved WebSocket close codes that cannot be set by applications (RFC 6455)
RESERVED_CLOSE_CODES = [1004, 1005, 1006, 1015].freeze

# Track active WebSocket connections for graceful shutdown
ACTIVE_CONNECTIONS = Set.new
CONNECTIONS_MUTEX  = Mutex.new

# ============================================================================
# SESSION AUTH - JWT tokens for production security
# ============================================================================

# Creates a signed JWT session token with a 1-hour expiry.
def create_session_token
  now = Time.now.to_i
  payload = {
    iat: now,
    exp: now + JWT_EXPIRY
  }
  JWT.encode(payload, SESSION_SECRET, "HS256")
end

# Verifies a JWT session token and checks expiry.
def validate_session_token(token)
  return false if token.nil? || token.empty?

  JWT.decode(token, SESSION_SECRET, true, algorithm: "HS256")
  true
rescue JWT::ExpiredSignature, JWT::DecodeError
  false
end

# Validates a token from WebSocket subprotocol: access_token.<jwt>
# Returns the full protocol string if valid, nil if invalid.
def validate_ws_token(protocols)
  return nil if protocols.nil? || protocols.empty?

  protocols.split(",").map(&:strip).each do |proto|
    if proto.start_with?("access_token.")
      token = proto.sub("access_token.", "")
      return proto if validate_session_token(token)
    end
  end

  nil
end

# ============================================================================
# WEBSOCKET HELPERS
# ============================================================================

# Returns a valid WebSocket close code.
# Reserved codes (1004, 1005, 1006, 1015) are translated to 1000 (normal closure).
def safe_close_code(code)
  if code.is_a?(Integer) && code >= 1000 && code <= 4999 && !RESERVED_CLOSE_CODES.include?(code)
    code
  else
    1000
  end
end

# ============================================================================
# SINATRA APPLICATION
# ============================================================================

set :port, PORT
set :bind, HOST
set :server, "puma"

configure do
  enable :cross_origin
end

before do
  response.headers["Access-Control-Allow-Origin"] = "*"
end

# ============================================================================
# HTTP ROUTES
# ============================================================================

# GET /api/session - Issue a signed session token
get "/api/session" do
  content_type :json
  { token: create_session_token }.to_json
end

# GET /api/metadata - Project metadata from deepgram.toml
get "/api/metadata" do
  content_type :json

  begin
    config = TomlRB.load_file("deepgram.toml")

    unless config["meta"]
      status 500
      return {
        error: "INTERNAL_SERVER_ERROR",
        message: "Missing [meta] section in deepgram.toml"
      }.to_json
    end

    config["meta"].to_json
  rescue StandardError => e
    $stderr.puts "Error reading metadata: #{e.message}"
    status 500
    {
      error: "INTERNAL_SERVER_ERROR",
      message: "Failed to read metadata from deepgram.toml"
    }.to_json
  end
end

# GET /health - Simple health check endpoint.
get "/health" do
  content_type :json
  { status: "ok" }.to_json
end

# OPTIONS for CORS preflight
options "*" do
  response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "Content-Type"
  200
end

# ============================================================================
# WEBSOCKET PROXY HANDLER
# ============================================================================

# Faye::WebSocket middleware for handling WebSocket upgrade requests
class WebSocketProxy
  def initialize(app)
    @app = app
  end

  def call(env)
    # Only handle WebSocket upgrades for /api/voice-agent
    if Faye::WebSocket.websocket?(env) && env["PATH_INFO"] == "/api/voice-agent"
      handle_voice_agent(env)
    else
      @app.call(env)
    end
  end

  private

  def handle_voice_agent(env)
    # Validate session token from subprotocol
    protocols = env["HTTP_SEC_WEBSOCKET_PROTOCOL"]
    valid_proto = validate_ws_token(protocols)

    unless valid_proto
      $stderr.puts "WebSocket auth failed: invalid or missing token"
      return [401, { "Content-Type" => "text/plain" }, ["Unauthorized"]]
    end

    # Accept the WebSocket connection with the validated subprotocol echoed back
    client_ws = Faye::WebSocket.new(env, [valid_proto])
    $stdout.puts "Client connected to /api/voice-agent"

    CONNECTIONS_MUTEX.synchronize { ACTIVE_CONNECTIONS.add(client_ws) }

    # Connect to Deepgram Voice Agent API
    # No query parameters needed -- config is sent via JSON after connection
    $stdout.puts "Initiating Deepgram connection..."

    deepgram_ws = Faye::WebSocket::Client.new(
      DEEPGRAM_AGENT_URL,
      nil,
      headers: { "Authorization" => "Token #{DEEPGRAM_API_KEY}" }
    )

    # Track whether connections are open
    deepgram_open = false

    # -- Deepgram events --

    deepgram_ws.on :open do |_event|
      deepgram_open = true
      $stdout.puts "Connected to Deepgram Agent API"
    end

    deepgram_ws.on :message do |event|
      if client_ws && client_ws.ready_state == Faye::WebSocket::API::OPEN
        # Forward message preserving type (binary or text)
        data = event.data
        if data.is_a?(Array)
          client_ws.send(data) # binary data as array of bytes
        elsif data.is_a?(String) && data.encoding == Encoding::ASCII_8BIT
          client_ws.send(data.bytes) # binary data as ASCII-8BIT string -> convert to bytes
        else
          client_ws.send(data) # text data
        end
      end
    end

    deepgram_ws.on :error do |event|
      $stderr.puts "Deepgram WebSocket error: #{event.message}"
      if client_ws && client_ws.ready_state == Faye::WebSocket::API::OPEN
        client_ws.send({
          type: "Error",
          description: event.message || "Deepgram connection error",
          code: "PROVIDER_ERROR"
        }.to_json)
      end
    end

    deepgram_ws.on :close do |event|
      code = event.code
      reason = event.reason || ""
      $stdout.puts "Deepgram connection closed: #{code} #{reason}"
      deepgram_open = false

      if client_ws && client_ws.ready_state == Faye::WebSocket::API::OPEN
        close_code = safe_close_code(code)
        client_ws.close(close_code, reason)
      end
    end

    # -- Client events --

    client_ws.on :message do |event|
      if deepgram_open && deepgram_ws
        # Forward message preserving type (binary or text)
        data = event.data
        if data.is_a?(Array)
          deepgram_ws.send(data) # binary data as array of bytes
        elsif data.is_a?(String) && data.encoding == Encoding::ASCII_8BIT
          deepgram_ws.send(data.bytes) # binary data as ASCII-8BIT string -> convert to bytes
        else
          deepgram_ws.send(data) # text data
        end
      end
    end

    client_ws.on :close do |event|
      $stdout.puts "Client disconnected: #{event.code} #{event.reason}"

      CONNECTIONS_MUTEX.synchronize { ACTIVE_CONNECTIONS.delete(client_ws) }

      if deepgram_open && deepgram_ws
        deepgram_ws.close(1000, "Client disconnected")
      end

      client_ws = nil
    end

    client_ws.on :error do |event|
      $stderr.puts "Client WebSocket error: #{event.message}"
      if deepgram_open && deepgram_ws
        deepgram_ws.close(1000, "Client error")
      end
    end

    # Return async Rack response for WebSocket
    client_ws.rack_response
  end
end

# Register WebSocket middleware
use WebSocketProxy

# ============================================================================
# GRACEFUL SHUTDOWN
# ============================================================================

shutdown_handler = proc do |sig|
  $stdout.puts "\n#{sig} signal received: starting graceful shutdown..."

  count = 0
  CONNECTIONS_MUTEX.synchronize do
    ACTIVE_CONNECTIONS.each do |ws|
      begin
        ws.close(1001, "Server shutting down")
        count += 1
      rescue StandardError => e
        $stderr.puts "Error closing WebSocket: #{e.message}"
      end
    end
  end
  $stdout.puts "Closed #{count} active WebSocket connection(s)"
  $stdout.puts "Shutdown complete"

  exit 0
end

trap("INT")  { shutdown_handler.call("SIGINT") }
trap("TERM") { shutdown_handler.call("SIGTERM") }

# ============================================================================
# STARTUP BANNER
# ============================================================================

puts ""
puts "=" * 70
puts "Backend API Server running at http://localhost:#{PORT}"
puts ""
puts "GET  /api/session"
puts "WS   /api/voice-agent (auth required)"
puts "GET  /api/metadata"
puts "GET  /health"
puts "=" * 70
puts ""
