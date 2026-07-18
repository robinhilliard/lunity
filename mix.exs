defmodule Lunity.MixProject do
  use Mix.Project

  def project do
    [
      app: :lunity,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r/test\/support\//],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def cli do
    [preferred_envs: ["test.apple_silicon": :test]]
  end

  defp aliases do
    [
      # Metal / MLX coverage (Emily). Excluded from default `mix test`.
      # Use `mix test --include apple_silicon` to run the full suite plus GPU cases.
      "test.apple_silicon": ["test --only apple_silicon"]
    ]
  end

  # Prefer a sibling checkout, then EAGL_PATH, then Hex — keeps CI/cloud agents working
  # without a local ../eagl clone while preserving the monorepo path for local work.
  defp eagl_dep do
    cond do
      path = System.get_env("EAGL_PATH") ->
        {:eagl, path: path}

      File.dir?(Path.expand("../eagl", __DIR__)) ->
        {:eagl, "~> 0.13", path: "../eagl"}

      true ->
        {:eagl, "~> 0.13"}
    end
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :wx],
      mod: {Lunity.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      eagl_dep(),
      {:nx, "~> 0.12"},
      {:exla, "~> 0.12"},
      {:jason, "~> 1.4"},
      {:joken, "~> 2.6"},
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.0"},
      {:websockex, "~> 0.5"},
      {:req, "~> 0.5"},
      {:png, "~> 0.2"},
      {:stb_image, "~> 0.6"},
      {:file_system, "~> 1.0"},
      {:luerl, "~> 1.5"},
      {:rustler, "~> 0.36"},
      {:ex_mcp, "~> 0.7"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ] ++ apple_mlx_deps()
  end

  # Emily/EMLX ship macOS arm64 NIFs; only pull them on Apple Silicon hosts.
  defp apple_mlx_deps do
    if apple_silicon?() do
      [{:emily, "~> 1.0"}]
    else
      []
    end
  end

  defp apple_silicon? do
    case :os.type() do
      {:unix, :darwin} ->
        :erlang.system_info(:system_architecture)
        |> List.to_string()
        |> String.contains?("aarch64")

      _ ->
        false
    end
  end
end
