# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.IntakeProfile do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :bio_text_1, :string, public?: true
    attribute :is_public?, :boolean, public?: true
  end
end

defmodule AshRpc.Test.IntakeSection do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :section_name, :string, allow_nil?: false, public?: true
    attribute :level_1, :integer, public?: true
    attribute :profile, AshRpc.Test.IntakeProfile, public?: true
  end
end

defmodule AshRpc.Test.IntakeStatus do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :status_type, :string, allow_nil?: false, public?: true
    attribute :message, :string, public?: true
    attribute :is_final?, :boolean, public?: true
  end
end
