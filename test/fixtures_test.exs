# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FixturesTest do
  use ExUnit.Case, async: true

  test "fixture resources persist through ETS" do
    author =
      AshRpc.Test.Author
      |> Ash.Changeset.for_create(:create, %{name: "Ada"})
      |> Ash.create!()

    assert author.is_active? == true
    assert [%{name: "Ada"}] = Ash.read!(AshRpc.Test.Author)
  end

  test "the manifest generator sees the :ash_rpc fixture domain and keeps entrypoint config" do
    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(
        otp_app: :ash_rpc,
        action_entrypoints: [
          %{
            resource: AshRpc.Test.Post,
            action: :read,
            config: %{ash_rpc_test: %{name: "list_posts"}}
          }
        ]
      )

    assert [%Ash.Info.Manifest.Entrypoint{resource: AshRpc.Test.Post, config: config}] =
             manifest.entrypoints

    assert config == %{ash_rpc_test: %{name: "list_posts"}}
    assert Enum.any?(manifest.resources, &(&1.module == AshRpc.Test.Secret))
    assert Enum.any?(manifest.types, &(&1.module == AshRpc.Test.PostSettings))
  end

  test "entrypoint row opts reach %AshRpc.Entrypoint{}" do
    runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)

    assert %AshRpc.Entrypoint{
             name: "get_post_by_slug_nullable",
             resource: AshRpc.Test.Post,
             action: :get_by_slug,
             get_by: [:slug],
             not_found_error?: false
           } = runtime.entrypoints["get_post_by_slug_nullable"]

    assert %AshRpc.Entrypoint{load_restrictions: {:allow, [comments: [:post]]}} =
             runtime.entrypoints["list_posts_allow_nested"]

    assert %AshRpc.Entrypoint{get?: false, not_found_error?: true, load_restrictions: :none} =
             runtime.entrypoints["list_posts"]
  end

  test "an unknown entrypoint opt fails the manifest build" do
    entrypoints = [
      %{
        resource: AshRpc.Test.Post,
        action: :read,
        config: %{ash_rpc_test: %{name: "bad", opts: [not_a_field: true]}}
      }
    ]

    assert_raise KeyError, fn ->
      entrypoints
      |> AshRpc.Test.ManifestBuilder.generate!()
      |> AshRpc.Manifest.Decorator.decorate(AshRpc.Test.MappingSource)
    end
  end

  test "new fixture resources persist, aggregate and calculate on ETS" do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Hello world", author_id: author.id})
    Ash.create!(AshRpc.Test.Comment, %{body: "b", rating: 4, approved: true, post_id: post.id})
    Ash.create!(AshRpc.Test.Comment, %{body: "a", rating: 2, post_id: post.id})

    post =
      Ash.load!(post, [
        :comment_count,
        :approved_comment_count,
        :has_comments,
        :avg_rating,
        :max_rating,
        :first_comment_body,
        :comment_bodies,
        :title_length,
        excerpt: %{length: 5}
      ])

    assert post.comment_count == 2
    assert post.approved_comment_count == 1
    assert post.has_comments == true
    assert post.avg_rating == 3.0
    assert post.max_rating == 4
    assert post.first_comment_body == "a"
    assert post.comment_bodies == ["a", "b"]
    assert post.title_length == 11
    assert post.excerpt == "Hello"

    assert %{post_count: 1, is_prolific?: false} =
             Ash.load!(author, [:post_count, :is_prolific?])

    note = Ash.create!(AshRpc.Test.Note, %{title: "n"}, tenant: "w1")
    Ash.create!(AshRpc.Test.NoteReply, %{body: "r", note_id: note.id}, tenant: "w1")
    assert [%{title: "n"}] = Ash.read!(AshRpc.Test.Note, tenant: "w1")
    assert [] = Ash.read!(AshRpc.Test.Note, tenant: "w2")
  end

  test "the Account fixture keeps private attributes out of the manifest" do
    runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)
    %Ash.Info.Manifest.Resource{fields: fields} = runtime.resource_lookup[AshRpc.Test.Account]

    assert Map.has_key?(fields, :embedding)
    refute Map.has_key?(fields, :secret)
    refute Map.has_key?(fields, :internal_notes)

    account = Ash.create!(AshRpc.Test.Account, %{handle: "a", secret: "s", embedding: [1, 2, 3]})
    assert account.secret == "s"
    assert %Ash.Vector{dimensions: 3} = account.embedding
  end

  test "Post.read_unviewed hides viewed posts" do
    Ash.create!(AshRpc.Test.Post, %{title: "seen", view_count: 1})
    Ash.create!(AshRpc.Test.Post, %{title: "unseen"})

    assert [%{title: "unseen"}] = Ash.read!(AshRpc.Test.Post, action: :read_unviewed)
  end
end
