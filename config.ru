# Rack configuration for Ruby Voice Agent Starter
# Uses Thin server with EventMachine for WebSocket support via Faye

require "./app"

Faye::WebSocket.load_adapter("thin")

run Sinatra::Application
