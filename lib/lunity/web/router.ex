defmodule Lunity.Web.Router do
  use Plug.Router

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  post "/api/player/token" do
    Lunity.Web.PlayerToken.call(conn, [])
  end

  get "/viewer" do
    viewer_path = Application.app_dir(:lunity, "priv/static/viewer.html")

    case File.read(viewer_path) do
      {:ok, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _} ->
        send_resp(conn, 404, "viewer.html not found")
    end
  end

  get "/player" do
    case player_html_abs_path() do
      {:ok, path} ->
        case File.read(path) do
          {:ok, html} ->
            conn
            |> put_resp_content_type("text/html")
            |> send_resp(200, html)

          {:error, _} ->
            send_resp(conn, 500, "player.html read failed")
        end

      {:error, _} ->
        send_resp(conn, 404, "player.html not found")
    end
  end

  get "/assets/prefabs/:name" do
    app = Lunity.project_app()
    priv_dir = Lunity.priv_dir_for_app(app)
    glb_name = if String.ends_with?(name, ".glb"), do: name, else: name <> ".glb"
    glb_path = Path.join([priv_dir, "prefabs", glb_name])

    if File.exists?(glb_path) do
      conn
      |> put_resp_content_type("model/gltf-binary")
      |> put_resp_header("cache-control", "public, max-age=3600")
      |> send_file(200, glb_path)
    else
      send_resp(conn, 404, "Prefab not found: #{glb_name}")
    end
  end

  defp player_html_abs_path do
    app = Lunity.project_app()
    game = Path.join([Lunity.priv_dir_for_app(app), "static", "player.html"])
    default = Application.app_dir(:lunity, "priv/static/player.html")

    cond do
      File.exists?(game) -> {:ok, game}
      File.exists?(default) -> {:ok, default}
      true -> {:error, :not_found}
    end
  end

  forward("/",
    to: ExMCP.HttpPlug,
    init_opts: [
      handler: Lunity.MCP.Server,
      server_info: %{name: "lunity", version: "0.1.0"},
      sse_enabled: true,
      cors_enabled: true
    ]
  )
end
