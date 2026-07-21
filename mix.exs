defmodule DevpulseAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :devpulse_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        devpulse: [
          steps: [:assemble, :tar],
          strip_beams: false
        ]
      ],
      burrito: [
        escript_main: DevpulseAgent.CLI,
        targets: [:macos, :macos_m1, :linux, :windows]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {DevpulseAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dotenvy, "~> 0.8.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:burrito, "~> 1.0"}
    ]
  end
end
