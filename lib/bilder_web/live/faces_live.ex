defmodule BilderWeb.FacesLive do
  @moduledoc """
  Start synthetic-face runs, follow the active one, and browse past runs.

  Runs execute in `Bilder.Biometrics.FaceRunner`, not in this process, so they
  continue if the page is closed; runs from `mix biometrics.faces` are listed too.
  """

  use BilderWeb, :live_view

  import BilderWeb.FaceComponents

  alias Bilder.Biometrics.{FacePrompts, FaceRunner, FaceRunRequest, FaceRuns}
  alias Bilder.ImageGeneration

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      FaceRunner.subscribe()
      send(self(), :check_service_status)
    end

    runs = FaceRuns.list_runs()

    socket =
      socket
      |> assign(:page_title, "Synthetic faces")
      |> assign(:service_status, :unknown)
      |> assign(:progress, FaceRunner.current())
      |> assign(:runs_empty?, runs == [])
      |> assign(:all_shots, FacePrompts.shots())
      |> assign_form(FaceRunRequest.changeset(%{}))
      |> stream(:runs, runs)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"face_run" => params}, socket) do
    changeset = params |> FaceRunRequest.changeset() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("start", %{"face_run" => params}, socket) do
    changeset = FaceRunRequest.changeset(params)

    with {:ok, request} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ready <- ImageGeneration.health(),
         {:ok, run} <- FaceRunner.start_run(FaceRunRequest.to_opts(request)) do
      {:noreply, push_navigate(socket, to: ~p"/faces/#{run}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "A run is already in progress.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      status ->
        {:noreply,
         socket
         |> assign(:service_status, status)
         |> put_flash(:error, "The Qwen-Image-2.1 service isn't ready.")}
    end
  end

  def handle_event("cancel", _params, socket) do
    :ok = FaceRunner.cancel()
    {:noreply, socket}
  end

  @impl true
  def handle_info(:check_service_status, socket) do
    status = ImageGeneration.health()
    next_check = if status == :ready, do: :timer.seconds(30), else: :timer.seconds(3)
    Process.send_after(self(), :check_service_status, next_check)
    {:noreply, assign(socket, :service_status, status)}
  end

  def handle_info({:face_run, event, progress}, socket) do
    terminal? = event in [:finished, :cancelled, :failed]

    socket =
      socket
      |> assign(:progress, if(terminal?, do: nil, else: progress))
      |> refresh_run(event, progress.run)

    socket =
      if event == :failed,
        do: put_flash(socket, :error, "Run #{progress.run} failed: #{progress.error}"),
        else: socket

    {:noreply, socket}
  end

  # Re-insert the run's card when its subject count or running state changes.
  defp refresh_run(socket, event, run)
       when event in [:started, :subject_done, :finished, :cancelled, :failed] do
    case FaceRuns.summary(run) do
      {:ok, summary} ->
        socket
        |> assign(:runs_empty?, false)
        |> stream_insert(:runs, summary, at: 0)

      {:error, :not_found} ->
        socket
    end
  end

  defp refresh_run(socket, _event, _run), do: socket

  defp assign_form(socket, changeset) do
    shots = Ecto.Changeset.get_field(changeset, :shots) || []
    subjects = Ecto.Changeset.get_field(changeset, :subjects) || 0
    images = max(subjects, 0) * length(Enum.uniq([FacePrompts.anchor_shot() | shots]))

    socket
    |> assign(:form, to_form(changeset, as: :face_run))
    |> assign(:selected_shots, shots)
    |> assign(:estimate, %{images: images, minutes: ceil(images * seconds_per_image() / 60)})
  end

  defp status_message(:unknown), do: "Checking the Qwen-Image-2.1 service…"
  defp status_message(:loading), do: "Qwen-Image-2.1 is starting up. This can take a while."

  defp status_message(:unreachable),
    do: "Couldn't reach the Qwen-Image-2.1 service. It starts with `mix phx.server`."

  defp status_message({:error, reason}), do: "Qwen-Image-2.1 failed to start: #{reason}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} wide>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Synthetic faces</h1>
          <p class="mt-1 max-w-2xl text-sm text-base-content/70">
            Mugshots, ICAO portraits and mated probe images of fictional people, generated locally
            with Qwen-Image-2.1. Every shot is conditioned on the subject's frontal mugshot.
          </p>
        </div>
        <span class="rounded-full border border-warning/40 bg-warning/10 px-3 py-1 text-xs font-medium text-base-content/70">
          Synthetic test data. Not real people, not for live systems.
        </span>
      </div>

      <div
        :if={@service_status != :ready}
        id="service-status"
        class="flex items-center gap-3 rounded-xl border border-info/30 bg-info/10 px-4 py-3 text-sm"
      >
        <.spinner :if={@service_status in [:unknown, :loading]} class="size-4 text-info" />
        {status_message(@service_status)}
      </div>

      <div class="grid gap-8 pt-2 lg:grid-cols-[minmax(0,360px)_minmax(0,1fr)]">
        <section class="h-fit rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm lg:sticky lg:top-20">
          <h2 class="text-sm font-semibold">New run</h2>
          <.form
            for={@form}
            id="face-run-form"
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
                max={FaceRunRequest.max_subjects()}
              />
              <.input
                field={@form[:steps]}
                type="select"
                label="Steps"
                options={FaceRunRequest.steps_options()}
              />
              <.input field={@form[:seed]} type="number" label="Seed" placeholder="random" />
              <.input field={@form[:run]} type="text" label="Run name" placeholder="automatic" />
            </div>

            <fieldset class="pt-2">
              <legend class="mb-2 text-sm font-medium">Shots</legend>
              <input type="hidden" name="face_run[shots][]" value="" />
              <div class="space-y-1">
                <label
                  :for={shot <- @all_shots}
                  for={"shot-#{shot}"}
                  class={[
                    "flex cursor-pointer items-start gap-3 rounded-lg px-2 py-1.5 transition hover:bg-base-200",
                    anchor?(shot) && "cursor-default opacity-80"
                  ]}
                >
                  <input
                    type="checkbox"
                    id={"shot-#{shot}"}
                    name="face_run[shots][]"
                    value={shot}
                    checked={anchor?(shot) or shot in @selected_shots}
                    disabled={anchor?(shot)}
                    class="mt-0.5 size-4 rounded border-base-300 accent-[var(--color-primary)]"
                  />
                  <span class="min-w-0">
                    <span class="flex items-center gap-2 text-sm">
                      {shot_label(shot)}
                      <.pos_badge pos={FacePrompts.spec(shot).pos} />
                      <span :if={anchor?(shot)} class="text-xs text-base-content/50">always</span>
                    </span>
                    <span class="block text-xs text-base-content/60">{shot_description(shot)}</span>
                  </span>
                </label>
              </div>
            </fieldset>

            <div class="flex items-center justify-between gap-3 border-t border-base-300 pt-4">
              <p id="run-estimate" class="text-xs text-base-content/60">
                {@estimate.images} images · about {@estimate.minutes} min
              </p>
              <.action_button
                type="submit"
                variant="primary"
                id="start-run"
                disabled={@service_status != :ready or not is_nil(@progress)}
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
                  navigate={~p"/faces/#{@progress.run}"}
                  class="font-mono font-medium underline-offset-4 hover:underline"
                >
                  {@progress.run}
                </.link>
              </div>
              <div class="flex items-center gap-2">
                <.link
                  navigate={~p"/faces/#{@progress.run}"}
                  class="rounded-lg px-3 py-1.5 text-sm font-medium text-primary transition hover:bg-primary/10"
                >
                  Watch
                </.link>
                <.action_button variant="danger" id="cancel-run" phx-click="cancel">
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
              No runs yet. Start one on the left, or run <code class="font-mono">mix biometrics.faces</code>.
            </div>
            <div id="runs" phx-update="stream" class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
              <.link
                :for={{dom_id, run} <- @streams.runs}
                id={dom_id}
                navigate={~p"/faces/#{run.name}"}
                class="group flex gap-4 rounded-2xl border border-base-300 bg-base-100 p-3 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md"
              >
                <div class="aspect-[4/5] w-20 shrink-0 overflow-hidden rounded-lg bg-base-200">
                  <img
                    :if={run.cover}
                    src={image_url(run.name, elem(run.cover, 0), elem(run.cover, 1))}
                    alt=""
                    loading="lazy"
                    class="size-full object-cover transition duration-300 group-hover:scale-105"
                  />
                </div>
                <div class="min-w-0 py-1">
                  <p class="truncate font-mono text-sm font-medium">{run.name}</p>
                  <p class="mt-1 text-xs text-base-content/60">{format_time(run.updated_at)}</p>
                  <p class="mt-2 text-xs text-base-content/70">
                    {run.completed}/{run.subjects} subjects · {length(run.shots)} shots
                  </p>
                  <p class="mt-1 flex flex-wrap gap-1.5 text-[11px] text-base-content/50">
                    <span>seed {run.seed}</span>
                    <span :if={run.prompt_version}>· {run.prompt_version}</span>
                  </p>
                  <span
                    :if={@progress && @progress.run == run.name}
                    class="mt-2 inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary"
                  >
                    <.spinner class="size-2.5" /> running
                  </span>
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
