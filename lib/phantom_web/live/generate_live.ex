defmodule PhantomWeb.GenerateLive do
  use PhantomWeb, :live_view

  alias Phantom.ImageGeneration

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:generating?, false)
      |> assign(:error, nil)
      |> assign(:aspect_ratios, ImageGeneration.aspect_ratios())
      |> assign(:form, generation_form())
      |> assign(:service_status, :unknown)
      |> stream(:generations, [])
      |> allow_upload(:reference_images,
        accept: ~w(.png .jpg .jpeg .webp),
        max_entries: ImageGeneration.max_reference_images(),
        max_file_size: 15_000_000
      )

    if connected?(socket), do: send(self(), :check_service_status)

    {:ok, socket}
  end

  @impl true
  def handle_info(:check_service_status, socket) do
    status = ImageGeneration.health()
    next_check = if status == :ready, do: :timer.seconds(30), else: :timer.seconds(3)
    Process.send_after(self(), :check_service_status, next_check)

    {:noreply, assign(socket, :service_status, status)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :reference_images, ref)}
  end

  def handle_event("generate", %{"generation" => params}, socket) do
    if socket.assigns.generating? do
      {:noreply, socket}
    else
      prompt = String.trim(params["prompt"] || "")

      case prompt do
        "" ->
          {:noreply, assign(socket, :error, "Please enter a prompt.")}

        prompt ->
          images =
            consume_uploaded_entries(socket, :reference_images, fn %{path: path}, entry ->
              {:ok,
               %{
                 data: File.read!(path),
                 filename: entry.client_name,
                 content_type: entry.client_type
               }}
            end)

          opts = [
            aspect_ratio: params["aspect_ratio"],
            steps: String.to_integer(params["steps"]),
            seed: parse_seed(params["seed"]),
            images: images
          ]

          socket =
            socket
            |> assign(:generating?, true)
            |> assign(:error, nil)
            |> assign(:form, generation_form(params))
            |> start_async(:generate, fn -> ImageGeneration.generate(prompt, opts) end)

          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_async(:generate, {:ok, {:ok, result}}, socket) do
    entry = Map.put(result, :id, result.path)

    socket =
      socket
      |> assign(:generating?, false)
      |> stream_insert(:generations, entry, at: 0)

    {:noreply, socket}
  end

  def handle_async(:generate, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:generating?, false) |> assign(:error, reason)}
  end

  def handle_async(:generate, {:exit, reason}, socket) do
    error = "Generation crashed: #{Exception.format_exit(reason)}"
    {:noreply, socket |> assign(:generating?, false) |> assign(:error, error)}
  end

  defp generation_form(params \\ %{}) do
    to_form(
      %{
        "prompt" => params["prompt"] || "",
        "aspect_ratio" => params["aspect_ratio"] || "1:1",
        "steps" => params["steps"] || "40",
        "seed" => params["seed"] || ""
      },
      as: :generation
    )
  end

  defp parse_seed(nil), do: nil
  defp parse_seed(""), do: nil

  defp parse_seed(value) do
    case Integer.parse(value) do
      {seed, ""} -> seed
      _ -> nil
    end
  end

  defp status_message(:unknown), do: "Checking the Qwen-Image-2.1 service…"

  defp status_message(:loading),
    do:
      "Qwen-Image-2.1 is starting up — the first run downloads the model, which can take a while…"

  defp status_message(:unreachable),
    do:
      "Couldn't reach the Qwen-Image-2.1 service. It should start automatically with the app — check the server logs."

  defp status_message({:error, reason}), do: "Qwen-Image-2.1 failed to start: #{reason}"

  defp upload_error_to_string(:too_large), do: "is too large (max 15MB)"
  defp upload_error_to_string(:not_accepted), do: "isn't a supported image type"

  defp upload_error_to_string(:too_many_files),
    do:
      "You've selected too many reference images (max #{ImageGeneration.max_reference_images()})."

  defp upload_error_to_string(_other), do: "couldn't be uploaded"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-3xl">
        <h1 class="text-2xl font-semibold tracking-tight">Phantom</h1>
        <p class="mt-1 text-base-content/70">
          Generate images locally with Qwen-Image-2.1.
        </p>

        <div :if={@service_status != :ready} id="service-status" class="mt-4 alert alert-info">
          <span
            :if={@service_status in [:unknown, :loading]}
            class="loading loading-spinner loading-sm"
          ></span>
          {status_message(@service_status)}
        </div>

        <.form
          for={@form}
          id="generate-form"
          phx-submit="generate"
          phx-change="validate"
          class="mt-8 flex flex-col gap-4 rounded-box border border-base-300 bg-base-100 p-5"
        >
          <div>
            <label for="generate-form_prompt" class="text-sm font-medium">Prompt</label>
            <textarea
              id="generate-form_prompt"
              name="generation[prompt]"
              rows="3"
              placeholder="A neon shop sign that reads &quot;PHANTOM&quot;, rainy night, reflections on wet pavement"
              class="textarea textarea-bordered mt-1 w-full"
              disabled={@generating?}
            >{@form[:prompt].value}</textarea>
          </div>

          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div>
              <label for="generate-form_aspect_ratio" class="text-sm font-medium">
                Aspect ratio
              </label>
              <select
                id="generate-form_aspect_ratio"
                name="generation[aspect_ratio]"
                class="select select-bordered mt-1 w-full"
                disabled={@generating?}
              >
                <option
                  :for={ratio <- @aspect_ratios}
                  value={ratio}
                  selected={ratio == @form[:aspect_ratio].value}
                >
                  {ratio}
                </option>
              </select>
            </div>

            <div>
              <label for="generate-form_steps" class="text-sm font-medium">Steps</label>
              <select
                id="generate-form_steps"
                name="generation[steps]"
                class="select select-bordered mt-1 w-full"
                disabled={@generating?}
              >
                <option
                  :for={steps <- ["20", "40", "50"]}
                  value={steps}
                  selected={steps == @form[:steps].value}
                >
                  {steps}
                </option>
              </select>
            </div>

            <div>
              <label for="generate-form_seed" class="text-sm font-medium">Seed (optional)</label>
              <input
                type="number"
                id="generate-form_seed"
                name="generation[seed]"
                value={@form[:seed].value}
                placeholder="random"
                class="input input-bordered mt-1 w-full"
                disabled={@generating?}
              />
            </div>
          </div>

          <div>
            <label class="text-sm font-medium">Reference images (optional)</label>
            <p class="text-xs text-base-content/60">
              Attach up to {ImageGeneration.max_reference_images()} images to generate from/with — mention them in your prompt (e.g. "put the hat from the first image on the cat in the second").
            </p>
            <.live_file_input
              upload={@uploads.reference_images}
              class="file-input file-input-bordered mt-1 w-full"
              disabled={@generating?}
            />

            <div :if={@uploads.reference_images.entries != []} class="mt-3 flex flex-wrap gap-3">
              <div :for={entry <- @uploads.reference_images.entries} class="relative">
                <.live_img_preview
                  entry={entry}
                  class="h-20 w-20 rounded-box border border-base-300 object-cover"
                />
                <button
                  type="button"
                  phx-click="cancel-upload"
                  phx-value-ref={entry.ref}
                  class="btn btn-circle btn-xs absolute -right-2 -top-2"
                  aria-label={"Remove #{entry.client_name}"}
                >
                  ✕
                </button>
                <p
                  :if={entry.progress < 100}
                  class="mt-1 w-20 text-center text-xs text-base-content/50"
                >
                  {entry.progress}%
                </p>
                <p
                  :for={err <- upload_errors(@uploads.reference_images, entry)}
                  class="mt-1 w-20 text-xs text-error"
                >
                  {upload_error_to_string(err)}
                </p>
              </div>
            </div>

            <p :for={err <- upload_errors(@uploads.reference_images)} class="mt-2 text-sm text-error">
              {upload_error_to_string(err)}
            </p>
          </div>

          <button
            type="submit"
            id="generate-button"
            class="btn btn-primary self-start"
            disabled={@generating? or @service_status != :ready}
          >
            <span :if={@generating?} class="loading loading-spinner loading-sm"></span>
            {if @generating?, do: "Generating…", else: "Generate"}
          </button>
        </.form>

        <div :if={@error} id="generate-error" class="mt-4 alert alert-error">
          {@error}
        </div>

        <div
          :if={@generating?}
          class="mt-8 flex aspect-square w-full max-w-md items-center justify-center rounded-box border border-dashed border-base-300 bg-base-200"
        >
          <span class="loading loading-spinner loading-lg text-base-content/50"></span>
        </div>

        <div id="generations" phx-update="stream" class="mt-8 grid grid-cols-1 gap-6 sm:grid-cols-2">
          <div
            :for={{id, generation} <- @streams.generations}
            id={id}
            class="overflow-hidden rounded-box border border-base-300 bg-base-100"
          >
            <a href={generation.path} target="_blank" rel="noopener noreferrer">
              <img src={generation.path} alt={generation.prompt} class="w-full" />
            </a>
            <div class="space-y-1 p-3 text-sm">
              <p class="text-base-content/80">{generation.prompt}</p>
              <p :if={generation.seed} class="text-xs text-base-content/50">
                seed: {generation.seed}
              </p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
