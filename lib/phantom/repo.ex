defmodule Phantom.Repo do
  use Ecto.Repo,
    otp_app: :phantom,
    adapter: Ecto.Adapters.Postgres
end
