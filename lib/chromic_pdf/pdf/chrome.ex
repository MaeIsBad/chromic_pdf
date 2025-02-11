# SPDX-License-Identifier: Apache-2.0

defmodule ChromicPDF.Chrome do
  @moduledoc false

  @callback spawn(keyword()) :: {:ok, port()}
  @callback send_msg(port(), msg :: binary()) :: :ok
end
