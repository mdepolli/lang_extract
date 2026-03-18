defmodule LangExtract.PromptValidator do
  @moduledoc """
  Validates that few-shot examples in a `PromptTemplate` are self-consistent.

  Each extraction text should align exactly against its own example's source text.
  Catches typos, hallucinated spans, and copy-paste errors before they reach the LLM.

  The validator is a pure function — it reports what it finds. The caller decides
  what to do with the results (log, raise, ignore).
  """

  alias LangExtract.{Aligner, ExampleData, Extraction, PromptTemplate}

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
            status: :fuzzy | :not_found
          }

    @enforce_keys [
      :example_index,
      :extraction_index,
      :example_text,
      :extraction_text,
      :extraction_class,
      :status
    ]
    defstruct [
      :example_index,
      :extraction_index,
      :example_text,
      :extraction_text,
      :extraction_class,
      :status
    ]
  end

  defmodule ValidationError do
    @moduledoc """
    Raised by `PromptValidator.validate!/1` when alignment issues are found.
    """

    defexception [:issues]

    @impl true
    def message(%{issues: issues}) do
      count = length(issues)
      "prompt validation failed: #{count} alignment issue(s) found"
    end
  end

  @spec validate(PromptTemplate.t(), keyword()) :: :ok | {:error, [Issue.t()]}
  def validate(%PromptTemplate{} = template, opts \\ []) do
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

  @spec validate!(PromptTemplate.t(), keyword()) :: :ok
  def validate!(%PromptTemplate{} = template, opts \\ []) do
    case validate(template, opts) do
      :ok -> :ok
      {:error, issues} -> raise ValidationError, issues: issues
    end
  end

  defp validate_example(%ExampleData{} = example, example_index, opts) do
    texts = Enum.map(example.extractions, & &1.text)
    spans = Aligner.align(example.text, texts, opts)

    example.extractions
    |> Enum.zip(spans)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{%Extraction{} = extraction, span}, extraction_index} ->
      case span.status do
        :exact ->
          []

        status ->
          [
            %Issue{
              example_index: example_index,
              extraction_index: extraction_index,
              example_text: example.text,
              extraction_text: extraction.text,
              extraction_class: extraction.class,
              status: status
            }
          ]
      end
    end)
  end
end
