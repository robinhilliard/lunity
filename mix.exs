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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:eagl, "~> 0.13", path: "../eagl"},
      {:ecsx, "~> 0.5"},
      {:ex_mcp, "~> 0.7"},
      {:stb_image, "~> 0.6"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
