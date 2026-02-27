# Rack configuration for Ruby Voice Agent Starter
# Uses Puma server with faye-websocket for WebSocket support

require "./app"

Faye::WebSocket.load_adapter("puma")

run Sinatra::Application
