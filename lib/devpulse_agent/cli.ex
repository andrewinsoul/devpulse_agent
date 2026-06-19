defmodule DevpulseAgent.CLI do
  @moduledoc """
  The main entry point for the Burrito standalone binary.
  This is executed when a user runs the compiled `./devpulse` file.
  """
  require Logger

  def main(args) do
    {parsed, _, _} =
      OptionParser.parse(
        args,
        switches: [
          path: :string,
          token: :string,
          server: :string
        ],
        aliases: [
          p: :path,
          t: :token,
          s: :server
        ]
      )

    target_dir = Keyword.get(parsed, :path, File.cwd!())

    Application.put_env(:devpulse_agent, :cli_token, parsed[:token])
    Application.put_env(:devpulse_agent, :cli_server, parsed[:server])
    Application.put_env(:devpulse_agent, :target_dir, target_dir)

    Application.ensure_all_started(:devpulse_agent)

    # Process.sleep(:infinity)
  end
end
