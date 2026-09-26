import Config

config :devpulse_agent,
  server_url: System.get_env("DEVPULSE_SERVER_URL", "http://localhost:4000/api/v1")

import_config "#{config_env()}.exs"
