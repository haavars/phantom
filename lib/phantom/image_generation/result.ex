defmodule Phantom.ImageGeneration.Result do
  @moduledoc "A single successfully generated image."

  defstruct [:path, :prompt, :seed]

  @type t :: %__MODULE__{
          path: String.t(),
          prompt: String.t(),
          seed: String.t() | nil
        }
end
