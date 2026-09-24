defmodule PhantomWeb.LandingLive do
  @moduledoc """
  The landing page: what Phantom is and how a synthetic subject is made, and a
  gallery of the identities generated so far (see `Phantom.Biometrics.Gallery`).
  """

  use PhantomWeb, :live_view

  import PhantomWeb.BiometricsComponents, only: [pattern_abbrev: 1, pattern_name: 1]

  alias Phantom.Biometrics.{Gallery, Shots}

  @filters [{"all", "All"}, {"faces", "With face"}, {"prints", "With fingerprints"}]

  @impl true
  def mount(_params, _session, socket) do
    identities = Gallery.identities()

    socket =
      socket
      |> assign(:page_title, "Synthetic identities")
      |> assign(:stats, Gallery.stats(identities))
      |> assign(:featured_face, Enum.find(identities, & &1.portrait))
      |> assign(:featured_print, Enum.find(identities, &(&1.prints != [])))
      |> assign(:filters, @filters)
      |> assign(:filter, "all")
      |> assign(:shown, length(identities))
      |> stream(:identities, identities)

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket)
      when filter in ["all", "faces", "prints"] do
    identities = Enum.filter(Gallery.identities(), &keep?(&1, filter))

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:shown, length(identities))
     |> stream(:identities, identities, reset: true)}
  end

  defp keep?(_identity, "all"), do: true
  defp keep?(identity, "faces"), do: identity.portrait != nil
  defp keep?(identity, "prints"), do: identity.prints != []

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
      <.hero stats={@stats} face={@featured_face} print={@featured_print} />
      <.how_it_works />
      <.modalities />

      <section id="gallery" class="scroll-mt-20 pt-16" aria-labelledby="gallery-title">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">Gallery</p>
            <h2 id="gallery-title" class="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">
              Identities generated so far
            </h2>
            <p class="mt-2 max-w-2xl text-sm text-base-content/65">
              Every card is one fictional person from a run. Open one to see all of their images,
              the prompts and the ground truth.
            </p>
          </div>
          <div
            id="gallery-filters"
            role="tablist"
            class="inline-flex rounded-full border border-base-300 bg-base-200/60 p-1 text-sm"
          >
            <button
              :for={{value, label} <- @filters}
              id={"filter-#{value}"}
              type="button"
              role="tab"
              aria-selected={to_string(@filter == value)}
              phx-click="filter"
              phx-value-filter={value}
              class={[
                "rounded-full px-3.5 py-1.5 font-medium transition",
                if(@filter == value,
                  do: "bg-base-100 text-base-content shadow-sm",
                  else: "text-base-content/60 hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <p id="gallery-count" class="mt-4 text-xs text-base-content/50">
          Showing {@shown} {if @shown == 1, do: "identity", else: "identities"}
        </p>

        <div
          id="identities"
          phx-update="stream"
          class="mt-4 grid gap-5 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
        >
          <div
            id="identities-empty"
            class="hidden rounded-2xl border border-dashed border-base-300 p-12 text-center only:block sm:col-span-2 lg:col-span-3 xl:col-span-4"
          >
            <.icon name="hero-finger-print" class="size-8 text-base-content/30" />
            <p class="mt-3 text-sm font-medium">No identities here yet</p>
            <p class="mt-1 text-sm text-base-content/60">
              Start a run to generate your first synthetic subjects.
            </p>
            <.link
              navigate={~p"/biometrics"}
              class="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary hover:underline"
            >
              Start a run <.icon name="hero-arrow-right-mini" class="size-4" />
            </.link>
          </div>
          <.identity_card
            :for={{dom_id, identity} <- @streams.identities}
            id={dom_id}
            identity={identity}
          />
        </div>
      </section>

      <footer class="mt-20 border-t border-base-300 pt-6 pb-4 text-xs text-base-content/50">
        <p class="flex items-start gap-2">
          <.icon name="hero-shield-exclamation-mini" class="mt-px size-4 shrink-0" />
          Synthetic test data. None of these people exist, and every file is labelled as synthetic.
          Don't use it as evidence of matching accuracy or send it to live systems.
        </p>
      </footer>
    </Layouts.app>
    """
  end

  attr :stats, :map, required: true
  attr :face, :map, default: nil
  attr :print, :map, default: nil

  defp hero(assigns) do
    ~H"""
    <section
      id="hero"
      class="relative isolate overflow-hidden rounded-3xl border border-base-300 bg-base-100"
    >
      <%!-- Concentric ridges, faded out towards the edges. --%>
      <div
        aria-hidden="true"
        class="pointer-events-none absolute inset-0 -z-10 text-base-content opacity-[0.07]"
        style="background: repeating-radial-gradient(ellipse 60% 70% at 78% 45%, currentColor 0 1.5px, transparent 1.5px 11px); mask-image: radial-gradient(ellipse 70% 80% at 78% 45%, black 20%, transparent 75%);"
      >
      </div>

      <div class="grid items-center gap-10 px-6 py-12 sm:px-10 lg:grid-cols-[1.1fr_1fr] lg:py-16">
        <div>
          <p class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100/80 px-3 py-1 text-xs font-medium text-base-content/70 backdrop-blur">
            <span class="size-1.5 rounded-full bg-primary"></span> Synthetic biometric test data
          </p>
          <h1 class="mt-5 text-4xl font-semibold leading-[1.05] tracking-tight text-balance sm:text-5xl">
            People who don't exist, down to the fingerprint.
          </h1>
          <p class="mt-5 max-w-xl text-base leading-relaxed text-base-content/70 text-pretty">
            Phantom generates fictional subjects for testing biometric systems. Each one gets a
            consistent face across mugshots, ICAO portraits and probe images, plus rolled
            fingerprints, slaps, palmprints and a tenprint card, all with ground truth you can check
            a matcher against.
          </p>
          <div class="mt-8 flex flex-wrap items-center gap-3">
            <.link
              id="cta-start"
              navigate={~p"/biometrics"}
              class="group inline-flex items-center gap-2 rounded-full bg-primary px-5 py-2.5 text-sm font-semibold text-primary-content shadow-sm transition hover:shadow-md hover:brightness-110"
            >
              Start a run
              <.icon
                name="hero-arrow-right-mini"
                class="size-4 transition-transform group-hover:translate-x-0.5"
              />
            </.link>
            <a
              id="cta-gallery"
              href="#gallery"
              class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-5 py-2.5 text-sm font-semibold transition hover:border-base-content/30 hover:bg-base-200"
            >
              Browse identities
            </a>
          </div>
          <dl class="mt-10 grid max-w-md grid-cols-3 gap-6 border-t border-base-300 pt-6">
            <div :for={
              {label, value} <- [
                {"Identities", @stats.identities},
                {"Images", @stats.images},
                {"Runs", @stats.runs}
              ]
            }>
              <dt class="text-xs text-base-content/55">{label}</dt>
              <dd class="mt-1 font-mono text-2xl font-semibold tabular-nums">{value}</dd>
            </div>
          </dl>
        </div>

        <.hero_visual face={@face} print={@print} />
      </div>
    </section>
    """
  end

  attr :face, :map, default: nil
  attr :print, :map, default: nil

  # A face card with a rolled print card overlapping it, or placeholders
  # before anything has been generated.
  defp hero_visual(assigns) do
    assigns =
      assign(assigns, :print_file, assigns.print && hero_print(assigns.print))

    ~H"""
    <div id="hero-visual" class="relative mx-auto h-[26rem] w-full max-w-md" aria-hidden="true">
      <div class="absolute left-0 top-0 w-[68%] rotate-[-4deg] overflow-hidden rounded-2xl border border-base-300 bg-base-200 shadow-xl transition duration-500 hover:rotate-[-2deg]">
        <div class="aspect-[4/5]">
          <%= if @face do %>
            <img
              src={file_url(@face, @face.portrait)}
              alt=""
              class="size-full object-cover"
              fetchpriority="high"
            />
          <% else %>
            <div class="grid size-full place-items-center text-base-content/25">
              <.icon name="hero-user" class="size-16" />
            </div>
          <% end %>
        </div>
        <div class="flex items-center justify-between gap-2 border-t border-base-300 bg-base-100 px-3 py-2">
          <span class="font-mono text-[11px] font-semibold tracking-wide">
            {(@face && @face.code) || "PH-0000-0000"}
          </span>
          <span class="rounded bg-base-content px-1.5 py-0.5 text-[9px] font-bold tracking-[0.15em] text-base-100">
            SYNTHETIC
          </span>
        </div>
      </div>

      <div class="absolute bottom-0 right-0 w-[56%] rotate-[5deg] overflow-hidden rounded-2xl border border-base-300 bg-white shadow-2xl transition duration-500 hover:rotate-[3deg]">
        <div class="aspect-[16/15] p-3">
          <%= if @print_file do %>
            <img
              src={file_url(@print, @print_file)}
              alt=""
              class="size-full object-contain mix-blend-multiply"
            />
          <% else %>
            <div class="grid size-full place-items-center text-neutral-300">
              <.icon name="hero-finger-print" class="size-16" />
            </div>
          <% end %>
        </div>
        <div class="flex items-center justify-between border-t border-neutral-200 px-3 py-2 text-neutral-700">
          <span class="text-[11px] font-medium">R index · rolled</span>
          <span class="font-mono text-[10px] text-neutral-500">500 ppi</span>
        </div>
      </div>
    </div>
    """
  end

  defp how_it_works(assigns) do
    assigns =
      assign(assigns, :steps, [
        {"hero-sparkles", "One seed, one person",
         "A single number fixes everything about a subject: age, sex, ancestry, hair and build, and a master ridge pattern for each finger and palm. The same seed always gives the same person."},
        {"hero-camera", "A consistent face",
         "Qwen-Image-2.1 renders a frontal mugshot first. Profiles, the ICAO portrait and the mated probes (aged, glasses, re-booking) are generated from it, so every shot shows the same face."},
        {"hero-finger-print", "Realistic friction ridges",
         "Each master pattern is pressed into rolled and plain impressions with its own distortion, contact area and ink. A diffusion model trained on real rolled prints then adds lifelike ink texture."},
        {"hero-check-badge", "Checked against ground truth",
         "NIST mindtct re-extracts minutiae from every print and compares them with the clean ridge map, and NFIQ 2 scores quality. bozorth3 confirms two captures of one finger match and different people don't."}
      ])

    ~H"""
    <section id="how-it-works" class="pt-16" aria-labelledby="how-title">
      <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">How it works</p>
      <h2 id="how-title" class="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">
        From a seed to a verified identity
      </h2>
      <ol class="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <li
          :for={{{icon, title, body}, index} <- Enum.with_index(@steps, 1)}
          class="group relative rounded-2xl border border-base-300 bg-base-100 p-5 transition hover:-translate-y-0.5 hover:border-base-content/20 hover:shadow-md"
        >
          <div class="flex items-center justify-between">
            <span class="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary transition group-hover:bg-primary group-hover:text-primary-content">
              <.icon name={icon} class="size-5" />
            </span>
            <span class="font-mono text-xs text-base-content/35">0{index}</span>
          </div>
          <h3 class="mt-4 font-semibold">{title}</h3>
          <p class="mt-2 text-sm leading-relaxed text-base-content/65">{body}</p>
        </li>
      </ol>
    </section>
    """
  end

  defp modalities(assigns) do
    assigns =
      assign(assigns, :items, [
        {"hero-user", "Faces",
         "Frontal and profile mugshots, an ICAO portrait, and mated probes."},
        {"hero-finger-print", "Rolled fingers",
         "All ten fingers, nail to nail, 800 × 750 px at 500 ppi."},
        {"hero-squares-2x2", "Slaps",
         "Right four, left four and both thumbs, as plain impressions."},
        {"hero-hand-raised", "Palmprints", "Full palms and writer's palms, both hands."},
        {"hero-identification", "Tenprint card",
         "An FD-249 style card built from the same impressions."},
        {"hero-code-bracket", "Ground truth",
         "JSON with minutiae, cores, deltas, pattern classes and verification scores."}
      ])

    ~H"""
    <section id="modalities" class="pt-16" aria-labelledby="modalities-title">
      <div class="grid gap-8 lg:grid-cols-[1fr_2fr]">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary">What you get</p>
          <h2 id="modalities-title" class="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">
            Every modality, one person
          </h2>
          <p class="mt-3 text-sm leading-relaxed text-base-content/65">
            All images of a subject belong together, and extra captures give you mated pairs. Runs
            are written to disk with an HTML contact sheet, so you can feed them straight into a
            test harness.
          </p>
        </div>
        <ul class="grid gap-px overflow-hidden rounded-2xl border border-base-300 bg-base-300 sm:grid-cols-2">
          <li :for={{icon, title, body} <- @items} class="flex gap-3 bg-base-100 p-4">
            <.icon name={icon} class="mt-0.5 size-5 shrink-0 text-base-content/50" />
            <div>
              <p class="text-sm font-medium">{title}</p>
              <p class="mt-0.5 text-sm text-base-content/60">{body}</p>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :identity, :map, required: true

  defp identity_card(assigns) do
    identity = assigns.identity

    assigns =
      assigns
      |> assign(:href, subject_path(identity))
      |> assign(:mosaic, Enum.filter(identity.prints, &(&1.fgp in [2, 3, 7, 8])))
      |> assign(:strip, Enum.take(identity.prints, 5))

    ~H"""
    <article id={@id} class="group">
      <.link
        navigate={@href}
        class="block overflow-hidden rounded-2xl border border-base-300 bg-base-100 transition duration-300 hover:-translate-y-1 hover:border-base-content/20 hover:shadow-xl focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
      >
        <div class="relative aspect-[4/5] overflow-hidden bg-base-200">
          <%= cond do %>
            <% @identity.portrait -> %>
              <img
                src={file_url(@identity, @identity.portrait)}
                alt={"Synthetic portrait of #{@identity.description}"}
                loading="lazy"
                class="size-full object-cover text-transparent transition duration-500 group-hover:scale-[1.03]"
              />
              <div
                :if={@strip != []}
                class="absolute inset-x-2 bottom-2 grid grid-cols-5 gap-1 rounded-lg bg-white/90 p-1 shadow backdrop-blur"
              >
                <img
                  :for={print <- @strip}
                  src={file_url(@identity, print.file)}
                  alt=""
                  loading="lazy"
                  class="aspect-square w-full object-cover text-transparent mix-blend-multiply"
                />
              </div>
            <% @mosaic != [] -> %>
              <div class="grid size-full grid-cols-2 gap-px bg-neutral-200">
                <div :for={print <- @mosaic} class="overflow-hidden bg-white">
                  <img
                    src={file_url(@identity, print.file)}
                    alt={"Rolled print, #{Shots.label(Path.rootname(print.file))}"}
                    loading="lazy"
                    class="size-full scale-[1.2] object-cover text-transparent mix-blend-multiply transition duration-500 group-hover:scale-[1.26]"
                  />
                </div>
              </div>
            <% true -> %>
              <div class="grid size-full place-items-center text-base-content/25">
                <.icon name="hero-user" class="size-12" />
              </div>
          <% end %>
          <span class="absolute left-2 top-2 rounded bg-base-content/85 px-1.5 py-0.5 text-[9px] font-bold tracking-[0.15em] text-base-100 backdrop-blur">
            SYNTHETIC
          </span>
        </div>

        <div class="space-y-3 p-4">
          <div class="flex items-baseline justify-between gap-2">
            <p class="font-mono text-sm font-semibold tracking-wide">{@identity.code}</p>
            <p :if={@identity.sex || @identity.age} class="text-xs text-base-content/60">
              {[sex_label(@identity.sex), @identity.age] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")}
            </p>
          </div>
          <p :if={@identity.description} class="line-clamp-2 text-sm text-base-content/70">
            {sentence(@identity.description)}
          </p>
          <ul class="flex flex-wrap gap-1.5">
            <li
              :for={{icon, label} <- chips(@identity.counts)}
              class="inline-flex items-center gap-1 rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-medium text-base-content/70"
            >
              <.icon name={icon} class="size-3" /> {label}
            </li>
          </ul>
          <div :if={@identity.prints != []} class="border-t border-base-200 pt-3">
            <p class="text-[10px] font-medium uppercase tracking-wider text-base-content/45">
              Pattern classes
            </p>
            <ol class="mt-1.5 grid grid-cols-10 gap-0.5">
              <li
                :for={print <- @identity.prints}
                title={"#{Shots.label(Path.rootname(print.file))}: #{pattern_name(print.pattern) || "unknown"}"}
                class={[
                  "rounded py-0.5 text-center font-mono text-[9px] font-semibold",
                  pattern_tone(print.pattern)
                ]}
              >
                {pattern_abbrev(print.pattern) || "–"}
              </li>
            </ol>
          </div>
        </div>
      </.link>
    </article>
    """
  end

  defp file_url(identity, file),
    do: ~p"/biometrics-files/#{identity.run}/#{identity.subject}/#{file}"

  defp subject_path(identity) do
    shot =
      cond do
        identity.portrait -> Path.rootname(identity.portrait)
        identity.prints != [] -> Path.rootname(hero_print(identity))
        true -> nil
      end

    params = Enum.reject([subject: identity.subject, shot: shot], fn {_k, v} -> is_nil(v) end)
    ~p"/biometrics/#{identity.run}?#{params}"
  end

  # The right index is the customary finger to show; fall back to the first.
  defp hero_print(%{prints: prints}) do
    Enum.find_value(prints, fn print -> print.fgp == 2 && print.file end) ||
      (List.first(prints) || %{file: nil}).file
  end

  defp chips(counts) do
    [
      {"face", "hero-user-micro", &"#{&1} face"},
      {"rolled", "hero-finger-print-micro", &"#{&1} rolled"},
      {"slaps", "hero-squares-2x2-micro", &"#{&1} slaps"},
      {"palms", "hero-hand-raised-micro", &"#{&1} palms"},
      {"card", "hero-identification-micro", fn _ -> "tenprint" end}
    ]
    |> Enum.flat_map(fn {group, icon, label} ->
      case counts[group] do
        nil -> []
        count -> [{icon, label.(count)}]
      end
    end)
  end

  defp sex_label("female"), do: "Female"
  defp sex_label("male"), do: "Male"
  defp sex_label(other), do: other

  defp sentence(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  defp pattern_tone("whorl"), do: "bg-primary/15 text-primary"

  defp pattern_tone(pattern) when pattern in ["left_loop", "right_loop"],
    do: "bg-base-200 text-base-content/70"

  defp pattern_tone(pattern) when pattern in ["arch", "tented_arch"], do: "bg-info/15 text-info"
  defp pattern_tone(_pattern), do: "bg-base-200 text-base-content/40"
end
