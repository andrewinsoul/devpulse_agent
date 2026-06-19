defmodule DevpulseAgent.Application do
  use Application

  defp print_logo do
    logo = ~S"""
               ____              ____        __
      /\      / __ \___ _   __  / __ \__  __/ /____ ___      /\
    _/  \/\_ / / / / _ \ | / / / /_/ / / / / / ___/ _ \    _/  \/\_
            / /_/ /  __/ |/ / / ____/ /_/ / (__  )  __/
           /_____/\___/|___/ /_/    \__,_/_/____/\___/...
    """

    IO.puts([IO.ANSI.green(), logo, IO.ANSI.reset()])
  end

  defp get_config_file do
    case :os.type() do
      {:win32, _} ->
        Path.join(
          System.get_env("APPDATA"),
          "DevPulse/config.toml"
        )

      {:unix, :darwin} ->
        Path.join(
          System.user_home!(),
          "Library/Application Support/DevPulse/config.toml"
        )

      _ ->
        Path.join(
          System.user_home!(),
          ".config/devpulse/config.toml"
        )
    end
  end

  defp save_config(token, server) do
    config_dir = Path.dirname(get_config_file())
    File.mkdir_p!(config_dir)

    config_file = get_config_file()

    existing =
      if File.exists?(config_file) do
        File.read!(config_file)
      else
        ""
      end

    updated =
      existing
      |> maybe_update_token(token)
      |> maybe_update_server(server)

    File.write!(config_file, updated)

    if DevpulseAgent.Env.dev?() do
      IO.puts("✅ Configuration saved to #{config_file}")
    else
      IO.puts("✅ Configuration saved to file...")
    end
  end

  defp maybe_update_token(content, nil), do: content

  defp maybe_update_token(content, token) do
    if String.contains?(content, "api_token") do
      Regex.replace(~r/api_token\s*=\s*"[^"]*"/, content, "api_token = \"#{token}\"")
    else
      content <> "\napi_token = \"#{token}\""
    end
  end

  defp maybe_update_server(content, nil), do: content

  defp maybe_update_server(content, server) do
    if String.contains?(content, "server_url") do
      Regex.replace(~r/server_url\s*=\s*"[^"]*"/, content, "server_url = \"#{server}\"")
    else
      content <> "\nserver_url = \"#{server}\""
    end
  end

  @impl true
  def start(_type, _args) do
    target_dir = Application.get_env(:devpulse_agent, :target_dir, File.cwd!())
    token = Application.get_env(:devpulse_agent, :cli_token)
    server_url = Application.get_env(:devpulse_agent, :cli_server)

    save_config(token, server_url)

    print_logo()

    IO.puts("🟢 DevPulse Agent started")
    IO.puts("📁 Monitoring: #{target_dir}")
    IO.puts("⏳ Press Ctrl+C to stop")

    children = [
      {DevpulseAgent.Agent, target_dir}
    ]

    opts = [strategy: :one_for_one, name: DevpulseAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
