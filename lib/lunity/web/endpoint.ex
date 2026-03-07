defmodule Lunity.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :lunity

  plug Lunity.Web.Router
end
