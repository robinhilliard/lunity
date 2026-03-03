defmodule Lunity.Extras do
  @moduledoc """
  Extras validation and utilities for glTF node custom data.

  ## Blender workflow (Phase 2.3)

  - **Flat property naming**: One Blender custom property = one config variable.
  - glTF extras use flat keys; in EAGL they become `node.properties["behaviour"]`, `node.properties["config"]`, etc.
  - Blender: Object Properties > Custom Properties (e.g. `behaviour`, `config`, `open_angle`).
  - Export: File > Export > glTF 2.0, enable **Include > Custom Properties**.
  - glTF extras are passed through as `node.properties` in EAGL.Node.

  ## Validation

  Phase 2: Basic validation—extras is a map with string keys.
  Phase 5: Full validation against behaviour module's `@extras_spec` (via `behaviour_properties` macro).
  """

  @doc """
  Basic validation of extras structure.

  Returns `:ok` if extras is valid, or `{:error, reason}` otherwise.
  Caller decides how to handle validation failure (fail load, retry, skip node, etc.).

  ## Valid extras

  - `nil` – no extras (valid)
  - `%{}` – empty map (valid)
  - `%{"behaviour" => "Door", "open_angle" => 90}` – map with string keys (valid)

  ## Invalid extras

  - `"not a map"` – `{:error, :extras_not_map}`
  - `%{behaviour: "Door"}` – atom keys – `{:error, :extras_keys_not_strings}`

  ## Examples

      iex> Lunity.Extras.validate_basic(nil)
      :ok

      iex> Lunity.Extras.validate_basic(%{})
      :ok

      iex> Lunity.Extras.validate_basic(%{"behaviour" => "Door"})
      :ok

      iex> Lunity.Extras.validate_basic("invalid")
      {:error, :extras_not_map}

      iex> Lunity.Extras.validate_basic(%{behaviour: "Door"})
      {:error, :extras_keys_not_strings}
  """
  @spec validate_basic(map() | nil) :: :ok | {:error, :extras_not_map | :extras_keys_not_strings}
  def validate_basic(nil), do: :ok
  def validate_basic(extras) when not is_map(extras), do: {:error, :extras_not_map}

  def validate_basic(extras) when is_map(extras) do
    if Enum.all?(extras, fn {k, _v} -> is_binary(k) end) do
      :ok
    else
      {:error, :extras_keys_not_strings}
    end
  end
end
