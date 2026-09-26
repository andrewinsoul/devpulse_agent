import Config

# The test suite does not exercise the interactive native terminal. Avoid
# requiring Cargo/Rustup just to compile the Elixir modules under test.
config :devpulse_agent, DevpulseAgent.Utils.Terminal, skip_compilation?: true
