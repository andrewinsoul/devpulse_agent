import Config

config :devpulse_agent,
  server_url: System.get_env("DEVPULSE_SERVER", "http://localhost:4000"),
  api_token: System.get_env("DEVPULSE_TOKEN", "your-default-dev-token")
