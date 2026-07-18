defmodule Lunity.Nx.Backend do
  @moduledoc """
  Selects and configures the best available Nx backend/compiler at runtime.

  ## Selection (`:auto`)

  Probes in order and uses the first usable option:

  1. **Emily** (Apple Silicon Metal / MLX) when the package is loaded
  2. **EMLX** (Apple Silicon Metal / MLX) when the package is loaded
  3. **EXLA** with a GPU/TPU client (`:cuda`, `:rocm`, `:tpu`)
  4. **EXLA** host client (still JIT-compiles `defn` on CPU)
  5. **Nx.BinaryBackend** as last resort

  On macOS arm64, MLX backends are preferred over EXLA host because EXLA has
  no Metal client.

  Override with `config :lunity, :nx, backend: :auto | :emily | :emlx | :exla | :binary`
  or env `LUNITY_NX_BACKEND`.
  """

  require Logger

  @type choice :: %{
          backend: term(),
          compiler: term() | nil,
          name: atom(),
          detail: String.t()
        }

  @doc """
  Configures the global Nx default backend and (when available) defn compiler.

  Safe to call multiple times. Returns the selected choice map.
  """
  @spec configure!(keyword()) :: choice()
  def configure!(opts \\ []) do
    choice = select(opts)
    apply_choice!(choice)
    choice
  end

  @doc "Returns the selected backend choice without applying it."
  @spec select(keyword()) :: choice()
  def select(opts \\ []) do
    requested = requested_backend(opts)

    case requested do
      :auto -> select_auto()
      :binary -> binary_choice("explicit")
      :emily -> select_named(:emily) || fallback_after_miss(:emily)
      :emlx -> select_named(:emlx) || fallback_after_miss(:emlx)
      :exla -> select_exla() || fallback_after_miss(:exla)
      other ->
        Logger.warning("Unknown lunity nx backend #{inspect(other)}; using :auto")
        select_auto()
    end
  end

  @doc "Applies a previously selected choice."
  @spec apply_choice!(choice()) :: :ok
  def apply_choice!(%{backend: backend, compiler: compiler, name: name, detail: detail}) do
    Nx.global_default_backend(backend)

    if compiler do
      Nx.Defn.global_default_options(compiler: compiler)
    end

    Logger.info("Lunity Nx backend=#{name} (#{detail})")
    :ok
  end

  # -- Selection ----------------------------------------------------------------

  defp select_auto do
    mlx =
      if apple_silicon?() do
        select_named(:emily) || select_named(:emlx)
      end

    mlx || select_exla_prefer_accelerator() || select_exla() ||
      binary_choice("no accelerator backend available")
  end

  defp select_named(:emily) do
    if Code.ensure_loaded?(Emily.Backend) and Code.ensure_loaded?(Emily.Compiler) do
      device = preferred_mlx_device()

      %{
        backend: {Emily.Backend, device: device},
        compiler: Emily.Compiler,
        name: :emily,
        detail: "device=#{device}"
      }
    end
  rescue
    _ -> nil
  end

  defp select_named(:emlx) do
    if Code.ensure_loaded?(EMLX.Backend) do
      device = preferred_mlx_device()
      compiler = if Code.ensure_loaded?(EMLX.Compiler), do: EMLX.Compiler, else: nil

      %{
        backend: {EMLX.Backend, device: device},
        compiler: compiler,
        name: :emlx,
        detail: "device=#{device}"
      }
    end
  rescue
    _ -> nil
  end

  defp select_exla_prefer_accelerator do
    case select_exla() do
      %{detail: detail} = choice ->
        # Reserve EXLA host for the later fallback so MLX can win on Mac Silicon.
        if String.contains?(detail, "client=host"), do: nil, else: choice

      nil ->
        nil
    end
  end

  defp select_exla do
    if Code.ensure_loaded?(EXLA) and Code.ensure_loaded?(EXLA.Backend) do
      client = exla_client()
      compiler = if Code.ensure_loaded?(EXLA), do: EXLA, else: nil

      %{
        backend: {EXLA.Backend, client: client},
        compiler: compiler,
        name: :exla,
        detail: "client=#{client}"
      }
    end
  rescue
    _ -> nil
  end

  defp fallback_after_miss(name) do
    Logger.warning("Requested Nx backend #{name} is unavailable; falling back to :auto")
    select_auto()
  end

  defp binary_choice(detail) do
    %{
      backend: Nx.BinaryBackend,
      compiler: nil,
      name: :binary,
      detail: detail
    }
  end

  defp requested_backend(opts) do
    cond do
      env = System.get_env("LUNITY_NX_BACKEND") ->
        env |> String.trim() |> String.downcase() |> String.to_atom()

      Keyword.has_key?(opts, :backend) ->
        Keyword.fetch!(opts, :backend)

      true ->
        Application.get_env(:lunity, :nx, [])
        |> Keyword.get(:backend, :auto)
    end
  end

  defp preferred_mlx_device do
    Application.get_env(:lunity, :nx, [])
    |> Keyword.get(:device, :gpu)
  end

  defp apple_silicon? do
    case :os.type() do
      {:unix, :darwin} ->
        :erlang.system_info(:system_architecture) |> List.to_string() |> String.contains?("aarch64")

      _ ->
        false
    end
  end

  defp exla_client do
    configured =
      Application.get_env(:lunity, :nx, [])
      |> Keyword.get(:exla_client)

    if configured do
      configured
    else
      platforms = exla_supported_platforms()

      cond do
        Map.has_key?(platforms, :cuda) -> :cuda
        Map.has_key?(platforms, :rocm) -> :rocm
        Map.has_key?(platforms, :tpu) -> :tpu
        true -> :host
      end
    end
  end

  defp exla_supported_platforms do
    if function_exported?(EXLA.Client, :get_supported_platforms, 0) do
      EXLA.Client.get_supported_platforms()
    else
      %{}
    end
  rescue
    _ -> %{}
  end
end
