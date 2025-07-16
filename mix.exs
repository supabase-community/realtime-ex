defmodule Supabase.Realtime.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/supabase-community/realtime-ex"

  def project do
    [
      app: :supabase_realtime,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      dialyzer: [plt_local_path: "priv/plts", ignore_warnings: ".dialyzerignore.exs"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Supabase.Realtime.Application, []}
    ]
  end

  defp deps do
    [
      {:supabase_potion, "~> 0.6"},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    %{
      licenses: ["MIT"],
      contributors: ["zoedsoupe"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/supabase_realtime"
      },
      files: ~w[lib mix.exs README.md LICENSE]
    }
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp description do
    """
    An isomorphic Elixir client for Supabase Realtime server
    """
  end
end
