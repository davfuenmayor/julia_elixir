defmodule JuliaElixir.Error do
  defexception [:message, :details]

  @impl true
  def exception(details) do
    %__MODULE__{message: format(details), details: details}
  end

  defp format(%{message: message}) when is_binary(message), do: message
  defp format(%{"message" => message}) when is_binary(message), do: message
  defp format(message) when is_binary(message), do: message
  defp format(details), do: inspect(details)
end
