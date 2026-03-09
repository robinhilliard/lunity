defmodule Lunity.MixProject do
  use Mix.Project

  def project do
    [
      app: :lunity,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
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
      {:eagl, "~> 0.13", path: "../eagl"},
      {:nx, "~> 0.9"},
      {:ex_mcp, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.7"},
      {:bandit, "~> 1.0"},
      {:png, "~> 0.2"},
      {:stb_image, "~> 0.6"},
      {:file_system, "~> 1.0"},
      {:luerl, "~> 1.5"},
      {:rustler, "~> 0.36"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
