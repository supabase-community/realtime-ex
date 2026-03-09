defmodule Supabase.Realtime.MixProject do
  use Mix.Project

  @version "0.3.0"
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
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_local_path: "priv/plts", ignore_warnings: ".dialyzerignore.exs"]
    ]
  end

  defp elixirc_paths(e) when e in [:dev, :test], do: ["lib", "test/support.ex"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger] ++ if(Mix.env() == :dev, do: [:wx, :observer], else: [])]
  end

  defp supabase_dep do
    if System.get_env("SUPABASE_LOCAL") == "1" do
      {:supabase_potion, path: "../supabase-ex"}
    else
      {:supabase_potion, "~> 0.7"}
    end
  end

  defp deps do
    [
      supabase_dep(),
      {:gun, "~> 2.1"},
      {:mimic, "~> 1.1", only: :test},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
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
