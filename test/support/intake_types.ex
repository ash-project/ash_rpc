# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.IntakeStats do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        total_count_1: [type: :integer, allow_nil?: false],
        is_complete?: [type: :boolean],
        last_updated_at: [type: :utc_datetime]
      ]
    ]
end

defmodule AshRpc.Test.IntakeInner do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        max_retries_1: [type: :integer, allow_nil?: false],
        is_cached?: [type: :boolean]
      ]
    ]
end

defmodule AshRpc.Test.IntakeDeep do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        display_name: [type: :string, allow_nil?: false],
        is_enabled_1?: [type: :boolean],
        inner: [type: AshRpc.Test.IntakeInner]
      ]
    ]
end

defmodule AshRpc.Test.IntakePrefs do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :keyword,
    constraints: [
      fields: [
        theme_1: [type: :string, allow_nil?: false],
        font_size: [type: :integer],
        is_dark_mode?: [type: :boolean]
      ]
    ]
end

defmodule AshRpc.Test.IntakeData do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        content_type: [type: :string],
        item_count: [type: :integer, allow_nil?: false],
        is_cached?: [type: :boolean]
      ]
    ]
end

defmodule AshRpc.Test.IntakeInput do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        item_name: [type: :string, allow_nil?: false],
        is_valid?: [type: :boolean]
      ]
    ]
end
