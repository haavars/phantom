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
  alias Phantom.Biometrics.{FacePrompts, RunRequest, Shots}

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

  defp assign_form(socket, changeset) do
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
    |> assign(:form, to_form(changeset, as: :batch))
    |> assign(:selected, shots)
    |> assign(:needs, %{
      face: Enum.any?(specs, &(&1.modality == :face)),
      ridge: Enum.any?(specs, &(&1.modality == :ridge))
    })
    |> assign(:estimate, %{
      images: subjects * length(ids),
      minutes: ceil(subjects * seconds / 60)
    })
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
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

      <div class="grid gap-8 pt-2 lg:grid-cols-[minmax(0,380px)_minmax(0,1fr)]">
        <section class="h-fit rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm lg:sticky lg:top-20">
          <h2 class="text-sm font-semibold">New run</h2>
          <.form
            for={@form}
            id="batch-form"
            phx-change="validate"
            phx-submit="start"
            class="mt-3 space-y-1"
          >
            <div class="grid grid-cols-2 gap-3">
              <.input
                field={@form[:subjects]}
                type="number"
                label="Subjects"
                min="1"
                max={RunRequest.max_subjects()}
              />
              <.input field={@form[:seed]} type="number" label="Seed" placeholder="random" />
            </div>
            <.input field={@form[:run]} type="text" label="Run name" placeholder="automatic" />

            <input type="hidden" name="batch[shots][]" value="" />

            <fieldset class="pt-2">
              <legend class="mb-2 flex w-full items-center justify-between text-sm font-medium">
                <span>Face</span>
                <span class="text-xs font-normal text-base-content/50">Qwen-Image-2.1 · GPU</span>
              </legend>
              <div class="space-y-0.5">
                <label
                  :for={shot <- @face_shots}
                  for={"shot-#{shot}"}
                  class="flex cursor-pointer items-start gap-3 rounded-lg px-2 py-1.5 transition hover:bg-base-200"
                >
                  <input
                    type="checkbox"
                    id={"shot-#{shot}"}
                    name="batch[shots][]"
                    value={shot}
                    checked={shot in @selected}
                    class="mt-0.5 size-4 rounded border-base-300 accent-[var(--color-primary)]"
                  />
                  <span class="min-w-0">
                    <span class="flex items-center gap-2 text-sm">
                      {shot_label(shot)} <.pos_badge pos={FacePrompts.spec(shot).pos} shot={shot} />
                      <span :if={anchor?(shot)} class="text-xs text-base-content/50">
                        added with any face shot
                      </span>
                    </span>
                    <span class="block text-xs text-base-content/60">{shot_description(shot)}</span>
                  </span>
                </label>
              </div>
              <div class="mt-2">
                <.input
                  field={@form[:steps]}
                  type="select"
                  label="Face steps"
                  options={RunRequest.steps_options()}
                />
              </div>
            </fieldset>

            <fieldset class="border-t border-base-300 pt-4">
              <legend class="mb-2 flex w-full items-center justify-between text-sm font-medium">
                <span>Friction ridge</span>
                <span class="text-xs font-normal text-base-content/50">
                  {renderer_note(@form[:renderer].value)} · 500 ppi
                </span>
              </legend>
              <div class="space-y-0.5">
                <label
                  :for={{group, name} <- @ridge_groups}
                  for={"group-#{group}"}
                  class="flex cursor-pointer items-start gap-3 rounded-lg px-2 py-1.5 transition hover:bg-base-200"
                >
                  <input
                    type="checkbox"
                    id={"group-#{group}"}
                    name="batch[shots][]"
                    value={group}
                    checked={group in @selected}
                    class="mt-0.5 size-4 rounded border-base-300 accent-[var(--color-primary)]"
                  />
                  <span class="min-w-0">
                    <span class="block text-sm">{name}</span>
                    <span class="block text-xs text-base-content/60">{group_description(group)}</span>
                  </span>
                </label>
              </div>
              <div class="mt-2 grid grid-cols-2 gap-3">
                <.input
                  field={@form[:renderer]}
                  type="select"
                  label="Renderer"
                  options={[{"Diffusion", "diffusion"}, {"Procedural (draft)", "procedural"}]}
                />
                <.input
                  field={@form[:captures]}
                  type="select"
                  label="Captures"
                  options={
                    Enum.map(
                      1..Shots.max_captures(),
                      &{if(&1 == 1, do: "1", else: "#{&1} (mated pairs)"), &1}
                    )
                  }
                />
              </div>
            </fieldset>

            <p :for={{message, _opts} <- @form[:shots].errors} class="text-sm text-error">
              Shots: {message}
            </p>

            <div class="flex items-center justify-between gap-3 border-t border-base-300 pt-4">
              <p id="run-estimate" class="text-xs text-base-content/60">
                {@estimate.images} images · about {@estimate.minutes} min
              </p>
              <.action_button
                type="submit"
                variant="primary"
                id="start-run"
                disabled={not can_start?(@services, @needs)}
                phx-disable-with="Starting…"
              >
                Start run
              </.action_button>
            </div>
          </.form>
        </section>

        <section class="min-w-0 space-y-6">
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

          <div>
            <h2 class="mb-3 text-sm font-semibold">Runs</h2>
            <div
              :if={@runs_empty?}
              id="runs-empty"
              class="rounded-2xl border border-dashed border-base-300 p-10 text-center text-sm text-base-content/60"
            >
              No runs yet. Start one on the left, or call
              <code class="font-mono">Phantom.Biometrics.create_run/1</code>
              from IEx.
            </div>
            <div id="runs" phx-update="stream" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
              <.link
                :for={{dom_id, run} <- @streams.runs}
                id={dom_id}
                navigate={~p"/biometrics/#{run.name}"}
                class="group flex gap-4 rounded-2xl border border-base-300 bg-base-100 p-3 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md"
              >
                <div class="aspect-[4/5] w-20 shrink-0 overflow-hidden rounded-lg bg-white">
                  <img
                    :if={run.cover}
                    src={image_url(run.cover)}
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
                  <.run_status
                    :if={run.status != :finished}
                    id={"run-status-#{run.name}"}
                    status={run.status}
                  />
                </div>
              </.link>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
