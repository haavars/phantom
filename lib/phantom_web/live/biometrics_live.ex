defmodule PhantomWeb.BiometricsLive do
  @moduledoc """
  Queue synthetic-biometrics runs (faces, fingerprints, palms), follow the
  one rendering now, and browse past runs.

  Runs render in Oban jobs (see `Phantom.Biometrics`), not in this process,
  so they continue if the page is closed; runs created from IEx with
  `Phantom.Biometrics.create_run/1` show up here too.
  """

  use PhantomWeb, :live_view

  import PhantomWeb.BiometricsComponents

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{FaceAttributes, FacePrompts, Generator, RunRequest, Shots, Traits}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Biometrics.subscribe()
      send(self(), :check_service_status)
    end

    runs = Biometrics.list_runs()

    socket =
      socket
      |> assign(:page_title, "Synthetic biometrics")
      |> assign(:services, %{face: :unknown, ridge: :unknown})
      |> assign(:progress, Biometrics.current_progress())
      |> assign(:runs_empty?, runs == [])
      |> assign(:face_shots, FacePrompts.shots())
      |> assign(:ridge_groups, Shots.ridge_groups())
      |> assign(:preview_seed, random_seed())
      |> assign_form(Biometrics.change_run_request())
      |> stream_configure(:runs, dom_id: &"runs-#{&1.name}")
      |> stream(:runs, runs)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"batch" => params}, socket) do
    changeset = params |> Biometrics.change_run_request() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  # Sets every trait back to random, keeping the rest of the form.
  def handle_event("random-traits", _params, socket) do
    {:noreply, change_params(socket, &Map.put(&1, "traits", %{}))}
  end

  def handle_event("clear-trait", %{"trait" => trait}, socket) do
    {:noreply,
     change_params(socket, fn params ->
       Map.update(params, "traits", %{}, &Map.delete(&1, trait))
     end)}
  end

  # Ticks all, the default or none of the face shots or friction-ridge groups.
  def handle_event("pick-shots", %{"modality" => modality, "set" => set}, socket) do
    {ids, default} =
      case modality do
        "face" -> {FacePrompts.shots(), FacePrompts.default_shots()}
        "ridge" -> {Enum.map(Shots.ridge_groups(), &elem(&1, 0)), []}
      end

    picked =
      case set do
        "all" -> ids
        "default" -> default
        "none" -> []
      end

    kept = Enum.reject(socket.assigns.selected, &(&1 in ids))
    {:noreply, change_params(socket, &Map.put(&1, "shots", kept ++ picked))}
  end

  def handle_event("another-example", _params, socket) do
    {:noreply,
     socket
     |> assign(:preview_seed, random_seed())
     |> assign_form(socket.assigns.changeset)}
  end

  def handle_event("start", %{"batch" => params}, socket) do
    case Biometrics.create_run(params) do
      {:ok, run} -> {:noreply, push_navigate(socket, to: ~p"/biometrics/#{run.name}")}
      {:error, changeset} -> {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("cancel", %{"run" => name}, socket) do
    with {:ok, run} <- Biometrics.get_run(name), do: Biometrics.cancel_run(run)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:check_service_status, socket) do
    services = Biometrics.service_status()
    all_ready? = Enum.all?(services, fn {_service, status} -> status == :ready end)

    Process.send_after(
      self(),
      :check_service_status,
      :timer.seconds(if all_ready?, do: 30, else: 3)
    )

    {:noreply, assign(socket, :services, services)}
  end

  def handle_info({:run_updated, run}, socket) do
    socket =
      socket
      |> assign(:runs_empty?, false)
      |> assign(:progress, Biometrics.current_progress())
      |> stream_insert(:runs, run, at: 0)

    socket =
      if run.status == :failed,
        do: put_flash(socket, :error, "Run #{run.name} failed: #{run.error}"),
        else: socket

    {:noreply, socket}
  end

  # An image finished somewhere: move the active run's progress along.
  def handle_info({:subject_updated, _subject}, socket) do
    {:noreply, assign(socket, :progress, Biometrics.current_progress())}
  end

  # The form as if the user had changed its params with `fun`.
  defp change_params(socket, fun) do
    changeset =
      (socket.assigns.changeset.params || %{})
      |> fun.()
      |> Biometrics.change_run_request()
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end

  defp assign_form(socket, changeset) do
    traits = changeset |> Ecto.Changeset.get_field(:traits) |> Traits.to_map()
    shots = Ecto.Changeset.get_field(changeset, :shots) || []
    captures = Ecto.Changeset.get_field(changeset, :captures) || 1
    subjects = max(Ecto.Changeset.get_field(changeset, :subjects) || 0, 0)

    ids =
      case Shots.expand(shots, captures) do
        {:ok, ids} -> ids
        {:error, _message} -> []
      end

    specs = Enum.map(ids, &Shots.spec/1)
    seconds = specs |> Enum.map(&seconds_per_image(&1.group)) |> Enum.sum()

    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset, as: :batch))
    |> assign(:selected, shots)
    |> assign(:traits, traits)
    |> assign(:example, example(changeset, traits, socket.assigns.preview_seed))
    |> assign(:needs, %{
      face: Enum.any?(specs, &(&1.modality == :face)),
      ridge: Enum.any?(specs, &(&1.modality == :ridge))
    })
    |> assign(:estimate, %{
      people: subjects,
      images: subjects * length(ids),
      minutes: ceil(subjects * seconds / 60)
    })
  end

  # The first subject of the run as the form stands (with a random seed when
  # the form has none), or nil while the traits aren't valid.
  defp example(changeset, traits, preview_seed) do
    traits_valid? =
      case Ecto.Changeset.get_change(changeset, :traits) do
        %Ecto.Changeset{valid?: valid?} -> valid?
        nil -> true
      end

    if traits_valid? do
      seed = Ecto.Changeset.get_field(changeset, :seed)

      attributes =
        (seed || preview_seed)
        |> Generator.derive_seed(1)
        |> FaceAttributes.sample(Traits.sample_opts(traits))

      %{description: FaceAttributes.describe(attributes), fixed_seed?: not is_nil(seed)}
    end
  end

  defp random_seed, do: :rand.uniform(2_147_483_646)

  defp sentence(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  # Options for a trait's select: labels without a leading article, and for
  # colours and textures only what the fixed ancestry has (plus the current
  # value, so changing the ancestry doesn't drop it).
  defp trait_options(:hair_style, _traits) do
    [
      {"Men's styles", FaceAttributes.hair_styles(:male)},
      {"Women's styles", FaceAttributes.hair_styles(:female)}
    ]
  end

  # With a fixed sex, the clothes for anyone and for that sex; otherwise all
  # of them, grouped.
  defp trait_options(:clothing, traits) do
    case traits["sex"] do
      sex when sex in ["female", "male"] ->
        sex
        |> String.to_existing_atom()
        |> FaceAttributes.clothing()
        |> with_current(traits["clothing"])
        |> Enum.map(&{option_label(&1), &1})

      _random ->
        for {group, items} <- FaceAttributes.clothing_groups(),
            do: {group, Enum.map(items, &{option_label(&1), &1})}
    end
  end

  defp trait_options(field, traits) do
    ancestry = traits["ancestry"]

    values =
      case field do
        :skin_tone -> FaceAttributes.skin_tones(ancestry)
        :eye_color -> FaceAttributes.eye_colors(ancestry)
        :hair_color -> FaceAttributes.hair_colors(ancestry)
        :hair_texture -> FaceAttributes.hair_textures(ancestry)
        :mark -> ["random" | FaceAttributes.marks()]
        field -> Traits.options(field)
      end

    values
    |> with_current(traits[Atom.to_string(field)])
    |> Enum.map(&{option_label(&1), &1})
  end

  defp with_current(values, current) do
    if is_nil(current) or current in values, do: values, else: values ++ [current]
  end

  defp option_label("none"), do: "None"
  defp option_label("random"), do: "Random (about 1 in 3 people)"
  defp option_label(value), do: value |> String.replace(~r/\A(a|an) /, "") |> sentence()

  # Runs queue behind the active one, but only start when the services their
  # shots need are up.
  defp can_start?(services, needs) do
    (needs.face or needs.ridge) and
      (not needs.face or services.face == :ready) and
      (not needs.ridge or services.ridge == :ready)
  end

  defp renderer_note("procedural"), do: "procedural · CPU"
  defp renderer_note(_diffusion), do: "diffusion · GPU"

  defp service_name(:face), do: "Qwen-Image-2.1 (faces)"
  defp service_name(:ridge), do: "Friction-ridge service (fingers, palms)"

  defp status_message(:unknown), do: "checking…"
  defp status_message(:loading), do: "starting up, this can take a while…"
  defp status_message(:unreachable), do: "unreachable. It starts with `mix phx.server`."
  defp status_message({:error, reason}), do: "failed: #{reason}"

  defp count_shots(run) do
    {faces, ridges} = Enum.split_with(run.shots, &Shots.face?/1)

    [faces != [] && "#{length(faces)} face", ridges != [] && "#{length(ridges)} ridge"]
    |> Enum.filter(& &1)
    |> Enum.join(" + ")
  end

  attr :id, :string, required: true
  attr :step, :integer, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :actions
  slot :inner_block, required: true

  # One numbered part of the new-run form.
  defp composer_section(assigns) do
    ~H"""
    <section id={@id} class="rounded-2xl border border-base-300 bg-base-100 shadow-sm">
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-5 py-3.5">
        <div class="flex items-center gap-3">
          <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary">
            {@step}
          </span>
          <div>
            <h2 class="text-sm font-semibold">{@title}</h2>
            <p class="text-xs text-base-content/60">{@subtitle}</p>
          </div>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-3">
          {render_slot(@actions)}
        </div>
      </header>
      <div class="p-5">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :disabled, :string, default: nil, doc: "why the trait doesn't apply, if it doesn't"
  attr :unset, :string, default: "Random", doc: "what leaving the trait unset means"

  # A trait: Random, or a value every subject gets (highlighted, with a button
  # back to Random).
  defp trait_select(assigns) do
    assigns = assign(assigns, :set?, is_nil(assigns.disabled) and filled?(assigns.field.value))

    ~H"""
    <div class="min-w-0">
      <div class="mb-1 flex h-4 items-center justify-between gap-2">
        <label
          for={@field.id}
          class={[
            "truncate text-xs font-medium",
            if(@set?, do: "text-primary", else: "text-base-content/70")
          ]}
        >
          {@label}
        </label>
        <button
          :if={@set?}
          type="button"
          id={"#{@field.id}_clear"}
          phx-click="clear-trait"
          phx-value-trait={@field.field}
          class="rounded text-base-content/40 transition hover:text-base-content"
          aria-label={"Set #{String.downcase(@label)} back to #{String.downcase(@unset)}"}
          title={"Back to #{String.downcase(@unset)}"}
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>
      <select
        id={@field.id}
        name={@field.name}
        disabled={not is_nil(@disabled)}
        class={[
          "select select-sm w-full",
          @set? && "border-primary bg-primary/5 font-medium text-base-content",
          @field.errors != [] && "select-error"
        ]}
      >
        <option :if={@disabled} value="">{@disabled}</option>
        <option :if={!@disabled} value="">{@unset}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
      </select>
      <p :for={error <- @field.errors} class="mt-1 text-xs text-error">{translate_error(error)}</p>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :trait?, :boolean, default: false, doc: "highlight it like a trait when it's set"
  attr :rest, :global, include: ~w(type min max placeholder)

  # A small text or number input that lines up with `trait_select/1`.
  defp compact_input(assigns) do
    assigns =
      assigns
      |> assign(:errors, if(used_input?(assigns.field), do: assigns.field.errors, else: []))
      |> assign(:set?, assigns.trait? and filled?(assigns.field.value))

    ~H"""
    <div class="min-w-0">
      <label
        for={@field.id}
        class={[
          "mb-1 block h-4 truncate text-xs font-medium",
          if(@set?, do: "text-primary", else: "text-base-content/70")
        ]}
      >
        {@label}
      </label>
      <input
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@rest[:type] || "text", @field.value)}
        class={[
          "input input-sm w-full",
          @set? && "border-primary bg-primary/5 font-medium",
          @errors != [] && "input-error"
        ]}
        {@rest}
      />
      <p :for={error <- @errors} class="mt-1 text-xs text-error">{translate_error(error)}</p>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  # Random, female or male, as a segmented control.
  defp sex_toggle(assigns) do
    assigns = assign(assigns, :current, to_string(assigns.field.value || ""))

    ~H"""
    <fieldset class="min-w-0">
      <legend class={[
        "mb-1 h-4 text-xs font-medium",
        if(@current == "", do: "text-base-content/70", else: "text-primary")
      ]}>
        Sex
      </legend>
      <div class="grid h-8 grid-cols-3 gap-0.5 rounded-lg bg-base-200 p-0.5">
        <label
          :for={{label, value} <- [{"Random", ""}, {"Female", "female"}, {"Male", "male"}]}
          for={"#{@field.id}_#{if value == "", do: "random", else: value}"}
          class={[
            "flex cursor-pointer items-center justify-center rounded-md px-2 text-xs text-base-content/60 transition hover:text-base-content",
            "has-[:checked]:bg-base-100 has-[:checked]:font-medium has-[:checked]:shadow-sm",
            "has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary",
            if(value == "",
              do: "has-[:checked]:text-base-content",
              else: "has-[:checked]:text-primary"
            )
          ]}
        >
          <input
            type="radio"
            id={"#{@field.id}_#{if value == "", do: "random", else: value}"}
            name={@field.name}
            value={value}
            checked={@current == value}
            class="sr-only"
          />
          {label}
        </label>
      </div>
    </fieldset>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true

  # A compact select for a section header (steps, renderer, captures).
  defp header_select(assigns) do
    ~H"""
    <label class="flex items-center gap-2 text-xs text-base-content/60">
      {@label}
      <select id={@field.id} name={@field.name} class="select select-xs w-auto">
        {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
      </select>
    </label>
    """
  end

  attr :modality, :string, required: true
  attr :sets, :list, required: true

  # "All · Default · None" links that tick shots of one modality.
  defp shot_picks(assigns) do
    ~H"""
    <div class="flex items-center gap-0.5 text-xs">
      <button
        :for={{label, set} <- @sets}
        type="button"
        id={"pick-#{@modality}-#{set}"}
        phx-click="pick-shots"
        phx-value-modality={@modality}
        phx-value-set={set}
        class="rounded-md px-1.5 py-0.5 font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
      >
        {label}
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  slot :inner_block, required: true

  # A shot or group as a selectable card.
  defp shot_card(assigns) do
    ~H"""
    <label
      for={@id}
      class="flex cursor-pointer items-start gap-3 rounded-xl border border-base-300 p-3 transition hover:border-primary/40 has-[:checked]:border-primary/60 has-[:checked]:bg-primary/5 has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary"
    >
      <input
        type="checkbox"
        id={@id}
        name="batch[shots][]"
        value={@value}
        checked={@checked}
        class="mt-0.5 size-4 shrink-0 rounded border-base-300 accent-[var(--color-primary)]"
      />
      <span class="min-w-0">{render_slot(@inner_block)}</span>
    </label>
    """
  end

  attr :service, :atom, required: true
  attr :status, :any, required: true

  defp service_line(assigns) do
    ~H"""
    <li id={"needs-#{@service}"} class="flex items-center gap-2">
      <span class={[
        "size-2 shrink-0 rounded-full",
        case @status do
          :ready -> "bg-success"
          status when status in [:unknown, :loading] -> "animate-pulse bg-warning"
          _down -> "bg-error"
        end
      ]}></span>
      <span class="min-w-0 truncate">{service_name(@service)}</span>
      <span class="ml-auto shrink-0 text-base-content/50">
        {if @status == :ready, do: "ready", else: short_status(@status)}
      </span>
    </li>
    """
  end

  defp short_status(:unknown), do: "checking"
  defp short_status(:loading), do: "starting"
  defp short_status(:unreachable), do: "unreachable"
  defp short_status({:error, _reason}), do: "failed"

  defp filled?(value), do: value not in [nil, ""]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide active={:runs}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Synthetic biometrics</h1>
          <p class="mt-1 max-w-2xl text-sm text-base-content/70">
            Fictional people with mugshots, ICAO portraits and mated probes (Qwen-Image-2.1), plus
            rolled fingerprints, slaps, palmprints and tenprint cards (synthetic ridge patterns,
            rendered as realistic ink prints and checked against their ground truth).
            All images of one subject show the same person, fingers and palms.
          </p>
        </div>
        <span class="rounded-full border border-warning/40 bg-warning/10 px-3 py-1 text-xs font-medium text-base-content/70">
          Synthetic test data. Not real people, not for live systems.
        </span>
      </div>

      <div
        :for={{service, status} <- @services}
        :if={status != :ready}
        id={"service-status-#{service}"}
        class="flex items-center gap-3 rounded-xl border border-info/30 bg-info/10 px-4 py-2.5 text-sm"
      >
        <.spinner :if={status in [:unknown, :loading]} class="size-4 text-info" />
        <span><span class="font-medium">{service_name(service)}:</span> {status_message(status)}</span>
      </div>

      <div
        :if={@progress}
        id="active-run"
        class="rounded-2xl border border-primary/30 bg-primary/5 p-5 shadow-sm"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-2 text-sm">
            <.spinner class="size-4 text-primary" />
            <span>Running</span>
            <.link
              navigate={~p"/biometrics/#{@progress.run}"}
              class="font-mono font-medium underline-offset-4 hover:underline"
            >
              {@progress.run}
            </.link>
          </div>
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/biometrics/#{@progress.run}"}
              class="rounded-lg px-3 py-1.5 text-sm font-medium text-primary transition hover:bg-primary/10"
            >
              Watch
            </.link>
            <.action_button
              variant="danger"
              id="cancel-run"
              phx-click="cancel"
              phx-value-run={@progress.run}
            >
              Cancel
            </.action_button>
          </div>
        </div>
        <.progress_bar value={run_fraction(@progress)} id="active-run-progress" />
        <p class="mt-3 text-sm text-base-content/70">
          Subject {min(@progress.done + 1, @progress.total)} of {@progress.total}
          <span :if={next_shot(@progress.shots, @progress.subject)}>
            · rendering {shot_label(next_shot(@progress.shots, @progress.subject))}
          </span>
        </p>
        <p :if={@progress.subject} class="mt-1 text-xs text-base-content/50">
          {@progress.subject.description}
        </p>
      </div>

      <.form
        for={@form}
        id="batch-form"
        phx-change="validate"
        phx-submit="start"
        class="grid items-start gap-6 pt-2 lg:grid-cols-[minmax(0,1fr)_340px]"
      >
        <input type="hidden" name="batch[shots][]" value="" />

        <div class="min-w-0 space-y-6">
          <.composer_section
            id="people-section"
            step={1}
            title="People"
            subtitle="How many, and what they have in common. Traits left on Random are picked for each person."
          >
            <:actions>
              <button
                :if={@traits != %{}}
                type="button"
                id="random-traits"
                phx-click="random-traits"
                class="rounded-md px-2 py-1 text-xs font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
              >
                Set all to random
              </button>
            </:actions>

            <.inputs_for :let={t} field={@form[:traits]}>
              <div class="grid gap-x-4 gap-y-3 sm:grid-cols-2 xl:grid-cols-4">
                <.compact_input
                  field={@form[:subjects]}
                  type="number"
                  label="Number of people"
                  min="1"
                  max={RunRequest.max_subjects()}
                />
                <.sex_toggle field={t[:sex]} />
                <div class="grid grid-cols-2 gap-2">
                  <.compact_input
                    field={t[:age_min]}
                    type="number"
                    label="Age from"
                    trait?
                    placeholder={"#{Traits.default_ages().first} · random"}
                    min={Traits.min_age()}
                    max={Traits.max_age()}
                  />
                  <.compact_input
                    field={t[:age_max]}
                    type="number"
                    label="to"
                    trait?
                    placeholder={"#{Traits.default_ages().last} · random"}
                    min={Traits.min_age()}
                    max={Traits.max_age()}
                  />
                </div>
                <.trait_select
                  field={t[:ancestry]}
                  label="Ancestry"
                  options={trait_options(:ancestry, @traits)}
                />
              </div>

              <div id="traits-fields" class="mt-4 border-t border-base-300 pt-4">
                <h3 class="mb-3 text-xs font-medium uppercase tracking-wide text-base-content/50">
                  Appearance
                </h3>
                <div class="grid grid-cols-2 gap-x-4 gap-y-3 xl:grid-cols-4">
                  <.trait_select
                    field={t[:skin_tone]}
                    label="Skin tone"
                    options={trait_options(:skin_tone, @traits)}
                  />
                  <.trait_select
                    field={t[:eye_color]}
                    label="Eye colour"
                    options={trait_options(:eye_color, @traits)}
                  />
                  <.trait_select
                    field={t[:hair_color]}
                    label="Hair colour"
                    options={trait_options(:hair_color, @traits)}
                  />
                  <.trait_select
                    field={t[:hair_texture]}
                    label="Hair texture"
                    options={trait_options(:hair_texture, @traits)}
                  />
                  <.trait_select
                    field={t[:hair_style]}
                    label="Hair style"
                    options={trait_options(:hair_style, @traits)}
                  />
                  <.trait_select
                    field={t[:facial_hair]}
                    label={if @traits["sex"] == "male", do: "Facial hair", else: "Facial hair (men)"}
                    options={trait_options(:facial_hair, @traits)}
                    disabled={if @traits["sex"] == "female", do: "None for women"}
                  />
                  <.trait_select
                    field={t[:face_shape]}
                    label="Face shape"
                    options={trait_options(:face_shape, @traits)}
                  />
                  <.trait_select
                    field={t[:build]}
                    label="Build"
                    options={trait_options(:build, @traits)}
                  />
                </div>
                <div class="mt-3 grid gap-x-4 gap-y-3 sm:grid-cols-2">
                  <.trait_select
                    field={t[:clothing]}
                    label="Clothing (mugshots)"
                    options={trait_options(:clothing, @traits)}
                  />
                  <.trait_select
                    field={t[:mark]}
                    label="Distinguishing mark"
                    unset="None"
                    options={trait_options(:mark, @traits)}
                  />
                </div>
              </div>
            </.inputs_for>
          </.composer_section>

          <.composer_section
            id="faces-section"
            step={2}
            title="Faces"
            subtitle="Qwen-Image-2.1 · GPU. Probes vary head angle and expression slightly."
          >
            <:actions>
              <.shot_picks
                modality="face"
                sets={[{"All", "all"}, {"Default", "default"}, {"None", "none"}]}
              />
              <span class="hidden h-4 w-px bg-base-300 sm:block"></span>
              <.header_select
                field={@form[:steps]}
                label="Steps"
                options={RunRequest.steps_options()}
              />
            </:actions>

            <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              <.shot_card
                :for={shot <- @face_shots}
                id={"shot-#{shot}"}
                value={shot}
                checked={shot in @selected}
              >
                <span class="flex flex-wrap items-center gap-2 text-sm font-medium">
                  {shot_label(shot)} <.pos_badge pos={FacePrompts.spec(shot).pos} shot={shot} />
                  <span
                    :if={anchor?(shot)}
                    class="rounded bg-base-200 px-1.5 py-0.5 text-[10px] font-normal text-base-content/60"
                  >
                    auto-added
                  </span>
                </span>
                <span class="mt-0.5 block text-xs text-base-content/60">
                  {shot_description(shot)}
                </span>
              </.shot_card>
            </div>
          </.composer_section>

          <.composer_section
            id="ridges-section"
            step={3}
            title="Friction ridge"
            subtitle={"#{renderer_note(@form[:renderer].value)} · 500 ppi. Fingers and palms come from the same person."}
          >
            <:actions>
              <.shot_picks modality="ridge" sets={[{"All", "all"}, {"None", "none"}]} />
              <span class="hidden h-4 w-px bg-base-300 sm:block"></span>
              <.header_select
                field={@form[:renderer]}
                label="Renderer"
                options={[{"Diffusion", "diffusion"}, {"Procedural (draft)", "procedural"}]}
              />
              <.header_select
                field={@form[:captures]}
                label="Captures"
                options={
                  Enum.map(
                    1..Shots.max_captures(),
                    &{if(&1 == 1, do: "1", else: "#{&1} (mated pairs)"), &1}
                  )
                }
              />
            </:actions>

            <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
              <.shot_card
                :for={{group, name} <- @ridge_groups}
                id={"group-#{group}"}
                value={group}
                checked={group in @selected}
              >
                <span class="block text-sm font-medium">{name}</span>
                <span class="mt-0.5 block text-xs text-base-content/60">
                  {group_description(group)}
                </span>
              </.shot_card>
            </div>
          </.composer_section>
        </div>

        <aside
          id="run-summary"
          class="space-y-5 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm lg:sticky lg:top-20"
        >
          <div>
            <h2 class="text-sm font-semibold">New run</h2>
            <dl id="run-estimate" class="mt-3 grid grid-cols-3 gap-2 text-center">
              <div class="rounded-xl bg-base-200/70 px-2 py-2.5">
                <dd id="estimate-people" class="text-lg font-semibold tabular-nums">
                  {@estimate.people}
                </dd>
                <dt class="text-[11px] text-base-content/60">
                  {if @estimate.people == 1, do: "person", else: "people"}
                </dt>
              </div>
              <div class="rounded-xl bg-base-200/70 px-2 py-2.5">
                <dd id="estimate-images" class="text-lg font-semibold tabular-nums">
                  {@estimate.images}
                </dd>
                <dt class="text-[11px] text-base-content/60">images</dt>
              </div>
              <div class="rounded-xl bg-base-200/70 px-2 py-2.5">
                <dd id="estimate-minutes" class="text-lg font-semibold tabular-nums">
                  ~{@estimate.minutes}
                </dd>
                <dt class="text-[11px] text-base-content/60">minutes</dt>
              </div>
            </dl>
          </div>

          <div>
            <h3 class="mb-1.5 text-xs font-medium text-base-content/60">Everyone in the run</h3>
            <p :if={@traits == %{}} id="traits-summary" class="text-sm text-base-content/70">
              Every trait is random for each person.
            </p>
            <div :if={@traits != %{}} id="traits-summary" class="flex flex-wrap gap-1">
              <span
                :for={phrase <- Traits.describe(@traits)}
                class="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
              >
                {phrase}
              </span>
            </div>
          </div>

          <div id="traits-example" class="rounded-xl border border-base-300 p-3">
            <div class="flex items-center justify-between gap-2">
              <span class="flex items-center gap-1.5 text-xs font-medium text-base-content/60">
                <.icon name="hero-user-circle" class="size-4" />
                {cond do
                  is_nil(@example) -> "Example person"
                  @example.fixed_seed? -> "Subject 1 of this run"
                  true -> "Example person"
                end}
              </span>
              <button
                :if={@example && !@example.fixed_seed?}
                type="button"
                id="another-example"
                phx-click="another-example"
                class="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium text-primary transition hover:bg-primary/10"
              >
                <.icon name="hero-arrow-path-mini" class="size-3.5" /> Another
              </button>
            </div>
            <p :if={@example} class="mt-1.5 text-sm leading-relaxed text-base-content/80">
              {sentence(@example.description)}
            </p>
            <p :if={!@example} class="mt-1.5 text-sm text-base-content/50">
              Fix the traits marked in red to see an example.
            </p>
          </div>

          <div class="grid grid-cols-2 gap-x-3 border-t border-base-300 pt-4">
            <.compact_input field={@form[:run]} type="text" label="Run name" placeholder="automatic" />
            <.compact_input field={@form[:seed]} type="number" label="Seed" placeholder="random" />
          </div>

          <ul
            :if={@needs.face or @needs.ridge}
            id="run-needs"
            class="space-y-1.5 text-xs text-base-content/70"
          >
            <.service_line :if={@needs.face} service={:face} status={@services.face} />
            <.service_line :if={@needs.ridge} service={:ridge} status={@services.ridge} />
          </ul>

          <p :for={{message, _opts} <- @form[:shots].errors} class="text-sm text-error">
            Shots: {message}
          </p>

          <.action_button
            type="submit"
            variant="primary"
            id="start-run"
            class="w-full"
            disabled={not can_start?(@services, @needs)}
            phx-disable-with="Starting…"
          >
            Start run
          </.action_button>
        </aside>
      </.form>

      <section id="runs-section" class="pt-6">
        <h2 class="mb-3 text-sm font-semibold">Runs</h2>
        <div
          :if={@runs_empty?}
          id="runs-empty"
          class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-sm text-base-content/60"
        >
          No runs yet. Start one above, or call
          <code class="font-mono">Phantom.Biometrics.create_run/1</code>
          from IEx.
        </div>
        <div
          id="runs"
          phx-update="stream"
          class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
        >
          <.link
            :for={{dom_id, run} <- @streams.runs}
            id={dom_id}
            navigate={~p"/biometrics/#{run.name}"}
            class="group flex min-w-0 gap-4 rounded-2xl border border-base-300 bg-base-100 p-3 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md"
          >
            <div class="aspect-[4/5] w-20 shrink-0 overflow-hidden rounded-lg bg-white">
              <img
                :if={run.cover}
                src={preview_url(run.cover)}
                alt=""
                loading="lazy"
                class="size-full object-cover transition duration-300 group-hover:scale-105"
              />
            </div>
            <div class="min-w-0 py-1">
              <p class="truncate font-mono text-sm font-medium">{run.name}</p>
              <p class="mt-1 text-xs text-base-content/60">{format_time(run.updated_at)}</p>
              <p class="mt-2 text-xs text-base-content/70">
                {run.completed_subjects}/{run.subject_count} subjects · {count_shots(run)} shots
              </p>
              <p class="mt-1 flex flex-wrap gap-1.5 text-[11px] text-base-content/50">
                <span>seed {run.seed}</span>
                <span :if={run.prompt_version}>· {run.prompt_version}</span>
              </p>
              <p
                :if={run.traits != %{}}
                id={"run-traits-#{run.name}"}
                class="mt-1 truncate text-[11px] text-base-content/60"
                title={Enum.join(Traits.describe(run.traits), " · ")}
              >
                {Enum.join(Traits.describe(run.traits), " · ")}
              </p>
              <.run_status
                :if={run.status != :finished}
                id={"run-status-#{run.name}"}
                status={run.status}
              />
            </div>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
