defmodule Lunity.Player.WsUrl do
  @moduledoc false

  @player_ws_path "/ws/player/websocket"

  @doc """
  Builds a `ws://` or `wss://` URL for Phoenix `PlayerSocket` from an HTTP(S) or WS(S) base URL
  and the shared `:player_ws_token` value.
  """
  @spec from_base_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def from_base_url(base_url, ws_token)
      when is_binary(ws_token) and ws_token != "" do
    uri = URI.parse(String.trim(base_url))

    with {:ok, scheme} <- ws_scheme(uri.scheme),
         {:ok, host} <- require_host(uri.host) do
      port = uri.port || default_port(scheme)
      path = @player_ws_path
      query = URI.encode_query(%{"token" => ws_token})

      built =
        %URI{scheme: scheme, host: host, port: port, path: path, query: query}
        |> URI.to_string()

      {:ok, built}
    end
  end

  def from_base_url(_, _), do: {:error, :bad_ws_token}

  defp ws_scheme("http"), do: {:ok, "ws"}
  defp ws_scheme("https"), do: {:ok, "wss"}
  defp ws_scheme("ws"), do: {:ok, "ws"}
  defp ws_scheme("wss"), do: {:ok, "wss"}
  defp ws_scheme(_), do: {:error, :bad_scheme}

  defp require_host(h) when is_binary(h) and h != "", do: {:ok, h}
  defp require_host(_), do: {:error, :bad_host}

  defp default_port("wss"), do: 443
  defp default_port("ws"), do: 80
end
