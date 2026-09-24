defmodule PhantomWeb.Layouts do
  @moduledoc """
  Phantom's page frame (`app/1`), the root HTML document
  (`layouts/root.html.heex`), flash messages and the theme toggle.
  """
  use PhantomWeb, :html

  embed_templates "layouts/*"

  @doc """
  The page frame: the header with the Phantom mark and navigation, the page
  content, and a footer saying the data is synthetic.

      <Layouts.app flash={@flash} active={:runs}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :wide, :boolean, default: false, doc: "use the full page width, for image grids"
  attr :active, :atom, default: nil, values: [nil, :overview, :runs], doc: "the current section"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col">
      <header class="sticky top-0 z-30 border-b border-base-300/80 bg-base-100/85 px-4 backdrop-blur-md sm:px-6 lg:px-8">
        <div class="mx-auto flex h-14 max-w-7xl items-center gap-2">
          <.link
            navigate={~p"/"}
            id="brand"
            class="mr-3 flex shrink-0 items-center gap-2.5 rounded-lg focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary"
            aria-label="Phantom, overview"
          >
            <img src={~p"/images/icon.svg"} class="size-7" alt="" />
            <span class="text-[15px] font-semibold tracking-tight">Phantom</span>
            <span class="hidden border-l border-base-300 pl-2.5 text-xs text-base-content/55 md:inline">
              Synthetic biometrics
            </span>
          </.link>

          <nav class="flex items-center gap-0.5 text-sm" aria-label="Main">
            <.nav_link id="nav-home" navigate={~p"/"} active={@active == :overview}>
              Overview
            </.nav_link>
            <.nav_link id="nav-biometrics" navigate={~p"/biometrics"} active={@active == :runs}>
              Runs
            </.nav_link>
          </nav>

          <div class="ml-auto flex items-center gap-3">
            <.link
              :if={@active != :runs}
              navigate={~p"/biometrics"}
              id="nav-new-run"
              class="hidden items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content shadow-sm transition hover:brightness-110 sm:inline-flex"
            >
              <.icon name="hero-plus-mini" class="size-4" /> New run
            </.link>
            <%!-- On phones the header has no room for it; it's in the footer there. --%>
            <.theme_toggle class="hidden sm:flex" />
          </div>
        </div>
      </header>

      <main class={["flex-1 px-4 sm:px-6 lg:px-8", if(@wide, do: "py-10", else: "py-20")]}>
        <div class={["mx-auto space-y-4", if(@wide, do: "max-w-7xl", else: "max-w-2xl")]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer id="site-footer" class="border-t border-base-300/80 px-4 sm:px-6 lg:px-8">
        <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-x-6 gap-y-2 py-6 text-xs text-base-content/55">
          <p class="flex items-center gap-2">
            <img src={~p"/images/icon.svg"} class="size-4" alt="" />
            <span class="font-medium text-base-content/70">Phantom</span>
            <span>Synthetic biometric test data</span>
          </p>
          <p class="flex items-center gap-1.5">
            <.icon name="hero-shield-exclamation-micro" class="size-3.5 shrink-0" />
            None of these people exist. Not for live systems or claims about matching accuracy.
          </p>
          <.theme_toggle id="theme-toggle-footer" class="sm:hidden" />
        </div>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "rounded-lg px-3 py-1.5 font-medium transition",
        if(@active,
          do: "bg-base-200 text-base-content",
          else: "text-base-content/60 hover:bg-base-200/70 hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting…")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Server error")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting…")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  System, light or dark theme, as a small segmented control. The choice is
  applied before the page renders (see `root.html.heex`).
  """
  attr :id, :string, default: "theme-toggle"
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    assigns =
      assign(assigns, :themes, [
        {"system", "hero-computer-desktop-micro", "System theme",
         "[[data-theme-source=system]_&]:bg-base-100 [[data-theme-source=system]_&]:text-base-content [[data-theme-source=system]_&]:shadow-sm"},
        {"light", "hero-sun-micro", "Light theme",
         "[[data-theme-source=user][data-theme=light]_&]:bg-base-100 [[data-theme-source=user][data-theme=light]_&]:text-base-content [[data-theme-source=user][data-theme=light]_&]:shadow-sm"},
        {"dark", "hero-moon-micro", "Dark theme",
         "[[data-theme-source=user][data-theme=dark]_&]:bg-base-100 [[data-theme-source=user][data-theme=dark]_&]:text-base-content [[data-theme-source=user][data-theme=dark]_&]:shadow-sm"}
      ])

    ~H"""
    <div
      id={@id}
      class={[
        "flex items-center gap-0.5 rounded-full border border-base-300 bg-base-200 p-0.5",
        @class
      ]}
      role="group"
      aria-label="Theme"
    >
      <button
        :for={{theme, icon, label, active} <- @themes}
        type="button"
        class={[
          "grid size-7 cursor-pointer place-items-center rounded-full text-base-content/50 transition hover:text-base-content",
          active
        ]}
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-4" />
      </button>
    </div>
    """
  end
end
