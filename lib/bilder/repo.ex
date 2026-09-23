defmodule Bilder.Repo do
  use Ecto.Repo,
    otp_app: :bilder,
    adapter: Ecto.Adapters.Postgres
end
