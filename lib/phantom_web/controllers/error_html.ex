defmodule PhantomWeb.ErrorHTML do
  @moduledoc """
  Error pages for HTML requests (see `config/config.exs`): branded pages for
  404 and 500 in `error_html/`, and the plain status message for the rest.
  They render without the app layout, so each is a whole document.
  """
  use PhantomWeb, :html

  embed_templates "error_html/*"

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  attr :status, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · Phantom</title>
        <link rel="icon" href={~p"/images/icon.svg"} type="image/svg+xml" />
        <link rel="icon" href={~p"/favicon.ico"} sizes="48x48" />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body class="grid min-h-screen place-items-center bg-base-200 p-6 text-base-content">
        <main class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-8 text-center shadow-sm">
          <img src={~p"/images/icon.svg"} class="mx-auto size-12" alt="Phantom" />
          <p class="mt-6 font-mono text-sm font-medium text-primary">{@status}</p>
          <h1 class="mt-1 text-2xl font-semibold tracking-tight">{@title}</h1>
          <p class="mt-3 text-sm leading-relaxed text-base-content/65">{render_slot(@inner_block)}</p>
          <div class="mt-8 flex flex-wrap justify-center gap-3">
            <a
              href={~p"/"}
              class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110"
            >
              Back to the overview
            </a>
            <a
              href={~p"/biometrics"}
              class="inline-flex items-center rounded-lg border border-base-300 px-4 py-2 text-sm font-medium transition hover:bg-base-200"
            >
              Runs
            </a>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
