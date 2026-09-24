defmodule PhantomWeb.RedirectController do
  use PhantomWeb, :controller

  def biometrics(conn, _params), do: redirect(conn, to: ~p"/biometrics")
end
