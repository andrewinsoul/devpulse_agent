import Config

if config_env() == :prod do
  config :logger,
    level: :error
end
