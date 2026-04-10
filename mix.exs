defmodule Tripswitch.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/tripswitch-dev/tripswitch-ex"

  def project do
    [
      app: :tripswitch_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Official Elixir SDK for Tripswitch — a circuit breaker management service",
      package: package(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      mod: {Tripswitch.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:mint, "~> 1.6"},
      # Dev / docs / lint
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Test
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Tripswitch" => "https://tripswitch.dev"
      }
    ]
  end

  defp docs do
    [
      main: "Tripswitch",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"]
    ]
  end
end
