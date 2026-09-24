defmodule PhantomWeb.RedirectControllerTest do
  use PhantomWeb.ConnCase, async: true

  test "GET / redirects to the biometrics page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/biometrics"
  end
end
