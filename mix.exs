defmodule Minne.MixProject do
  use Mix.Project

  def project do
    [
      app: :minne,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: []
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.17"},
      {:ex_aws, "~> 2.2", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:hackney, "~> 1.23", optional: true},
      {:sweet_xml, "~> 0.6.6", optional: true}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
