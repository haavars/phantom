defmodule PhantomWeb.ErrorHTMLTest do
  use PhantomWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders a branded 404 page" do
    html = render_to_string(PhantomWeb.ErrorHTML, "404", "html", [])
    assert html =~ "<title>Page not found · Phantom</title>"
    assert html =~ ~s(src="/images/icon.svg")
    assert html =~ ~s(href="/")
  end

  test "renders a branded 500 page" do
    html = render_to_string(PhantomWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Something went wrong on our side"
  end

  test "renders the plain status message for other errors" do
    assert render_to_string(PhantomWeb.ErrorHTML, "403", "html", []) == "Forbidden"
  end
end
