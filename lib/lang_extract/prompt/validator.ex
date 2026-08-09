defmodule LangExtract.Prompt.Validator do
  @moduledoc """
  Validates that few-shot examples in a `LangExtract.Template` are self-consistent.

  Each extraction text should align exactly against its own example's source text.
  Catches typos, hallucinated spans, and copy-paste errors before they reach the LLM.

  Deliberately uses the production `Alignment.Aligner`, so a passing validation
  predicts how the same extractions align at runtime.

  The validator is a pure function — it reports what it finds. The caller decides
  what to do with the results (log, raise, ignore).
  """

  alias LangExtract.Alignment.Aligner
  alias LangExtract.{Extraction, Template}
  alias LangExtract.Template.Example

  defmodule Issue do
    @moduledoc """
    Describes a single alignment problem in a few-shot example.
    """

    @type t :: %__MODULE__{
            example_index: non_neg_integer(),
            extraction_index: non_neg_integer(),
            example_text: String.t(),
            extraction_text: String.t(),
            extraction_class: String.t(),
            status: :lesser | :fuzzy | :not_found
          }

    @fields [
      :example_index,
      :extraction_index,
      :example_text,
      :extraction_text,
      :extraction_class,
      :status
    ]
    @enforce_keys @fields
    defstruct @fields
  end

  defmodule ValidationError do
    @moduledoc """
    Raised by `LangExtract.template/2` when a template's examples have
    alignment issues.
    """

    defexception [:issues]

    @impl true
    def message(%{issues: issues}) do
      count = length(issues)
      "prompt validation failed: #{count} alignment issue(s) found"
    end
  end

  @spec validate(Template.t(), keyword()) :: :ok | {:error, [Issue.t()]}
  def validate(%Template{} = template, opts \\ []) do
    issues =
      template.examples
      |> Enum.with_index()
      |> Enum.flat_map(fn {example, example_index} ->
        validate_example(example, example_index, opts)
      end)

    case issues do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  defp validate_example(%Example{} = example, example_index, opts) do
    example
    |> pair_spans(opts)
    |> Enum.with_index()
    |> Enum.map(fn {{extraction, span}, extraction_index} ->
      issue_for(example, example_index, extraction, extraction_index, span)
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Aligner takes bare texts; extractions rejoin at this boundary only.
  # The texts list never outlives pair_spans/2.
  defp pair_spans(%Example{text: source, extractions: extractions}, opts) do
    texts = Enum.map(extractions, & &1.text)

    source
    |> Aligner.align(texts, opts)
    |> Enum.zip_with(extractions, fn span, extraction -> {extraction, span} end)
  end

  defp issue_for(_example, _example_index, _extraction, _extraction_index, %{status: :exact}),
    do: nil

  defp issue_for(
         %Example{text: example_text},
         example_index,
         %Extraction{text: extraction_text, class: extraction_class},
         extraction_index,
         %{status: status}
       ) do
    %Issue{
      example_index: example_index,
      extraction_index: extraction_index,
      example_text: example_text,
      extraction_text: extraction_text,
      extraction_class: extraction_class,
      status: status
    }
  end
end
