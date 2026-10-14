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

  test "the Widget fixture stores tagged, map_with_tag and array unions" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "featured"})

    widget =
      Ash.create!(AshRpc.Test.Widget, %{
        content: %{content_type: "text", text: "hi"},
        status: %{status_type: "simple", note: "ok"},
        attachments: [%{attachment_type: "file", filename: "a.txt"}, "https://example.com"],
        post_id: post.id
      })

    assert %Ash.Union{type: :text, value: %AshRpc.Test.TextBlock{text: "hi"}} = widget.content
    assert %Ash.Union{type: :simple} = widget.status
    assert [%Ash.Union{type: :file}, %Ash.Union{type: :url}] = widget.attachments

    assert %{featured: %Ash.Union{type: :post, value: %AshRpc.Test.Post{title: "featured"}}} =
             Ash.load!(widget, :featured)
  end

  test "the Place fixture stores keyword, tuple and tuple NewType values" do
    place =
      Ash.create!(AshRpc.Test.Place, %{
        options: [priority: 3, category: "home", notify: true],
        coordinates: {1.5, 2.5},
        location: {10.0, 20.0, true}
      })

    assert [priority: 3, category: "home", notify: true] = place.options
    assert {1.5, 2.5} = place.coordinates
    assert {10.0, 20.0, true} = place.location

    assert {:ok, [priority: 8, category: "work", notify: true, theme: :dark]} =
             AshRpc.Test.Place
             |> Ash.ActionInput.for_action(:keyword_options, %{})
             |> Ash.run_action()
  end

  test "the Project fixture holds embedded, custom, typed-struct and aggregate values" do
    project =
      Ash.create!(AshRpc.Test.Project, %{
        metadata: %{category: "work", priority_score: 5, internal_notes: "hidden"},
        history: [%{category: "old"}],
        palette: %{"primary" => "#000", "secondary" => "#fff"},
        due_date: ~D[2099-12-31],
        priority: :high,
        stats: %{view_count: 1, metrics: %{focus_seconds: 10}}
      })

    Ash.create!(AshRpc.Test.ProjectNote, %{
      project_id: project.id,
      body: "n",
      meta: %{category: "note"},
      author_info: %{info_type: "meta", category: "author"}
    })

    assert %{primary: "#000", secondary: "#fff"} = project.palette
    assert %AshRpc.Test.ProjectStats{view_count: 1} = project.stats

    loaded =
      Ash.load!(project, [
        :summary,
        :report,
        :is_late,
        :days_left,
        :first_note_meta,
        :first_note_author_info,
        self: %{prefix: "p"},
        metadata: [adjusted_priority: %{multiplier: 2}]
      ])

    assert %AshRpc.Test.ProjectStats{view_count: 42} = loaded.summary
    assert %{total: 2, rows: [_, _]} = loaded.report
    assert loaded.is_late == false
    assert loaded.days_left == Date.diff(~D[2099-12-31], Date.utc_today())
    assert %AshRpc.Test.ProjectMeta{category: "note"} = loaded.first_note_meta
    assert %Ash.Union{type: :meta} = loaded.first_note_author_info
    assert %AshRpc.Test.Project{} = loaded.self
    assert loaded.metadata.adjusted_priority == 10

    runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)

    %Ash.Info.Manifest.Resource{fields: meta_fields} =
      runtime.resource_lookup[AshRpc.Test.ProjectMeta]

    refute Map.has_key?(meta_fields, :internal_notes)
  end

  test "the Catalog fixture's generic actions return their declared shapes" do
    Ash.create!(AshRpc.Test.Post, %{title: "listed"})
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})

    run = fn action, args ->
      AshRpc.Test.Catalog |> Ash.ActionInput.for_action(action, args) |> Ash.run_action!()
    end

    assert [%AshRpc.Test.Post{title: "listed"}] = run.(:search_posts, %{})
    assert [_id] = run.(:post_ids, %{})

    assert %AshRpc.Test.TaskStats{total_count: 10, completed?: true} =
             run.(:task_stats, %{task_id: Ash.UUID.generate()})

    assert [%{"_id" => "a1"}] = run.(:raw_rows, %{})
    assert ~D[2025-01-15] = run.(:publication_date, %{})
    assert %{total_count: 1, settings_rows: [%AshRpc.Test.PostSettings{}]} = run.(:digest, %{})
    assert %{assignee_name: "Ada"} = run.(:assign, %{assignee: author})
  end

  test "the Intake fixture casts every override-bearing shape" do
    intake =
      Ash.create!(AshRpc.Test.Intake, %{
        user_name: "ada",
        is_active?: true,
        version_1: 2,
        settings: %{notification_enabled: true},
        stats: %{total_count_1: 3, is_complete?: false},
        deep: %{display_name: "d", inner: %{max_retries_1: 4}},
        preferences: [theme_1: "dark"],
        location: {1.0, 2.0, false},
        profile: %{display_name: "p", bio_text_1: "bio"},
        history: [%{display_name: "h"}],
        section: %{section_name: "s", profile: %{display_name: "inner"}},
        content: %{content_type: "data", item_count: 1},
        status: %{status_type: "active", message: "m"}
      })

    assert %{total_count_1: 3} = intake.stats
    assert %{inner: %{max_retries_1: 4}} = intake.deep

    assert %AshRpc.Test.IntakeSection{profile: %AshRpc.Test.IntakeProfile{display_name: "inner"}} =
             intake.section

    assert %Ash.Union{type: :data} = intake.content
    assert %Ash.Union{type: :active, value: %AshRpc.Test.IntakeStatus{}} = intake.status
  end

  test "Post's gated relationships and its has_many to the unexposed Secret load" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "p"})
    Ash.create!(AshRpc.Test.Comment, %{body: "c", post_id: post.id})
    Ash.create!(AshRpc.Test.Secret, %{code: "s", post_id: post.id})

    assert %{
             unfilterable_comments: [%{body: "c"}],
             unsortable_comments: [%{body: "c"}],
             secrets: [%{code: "s"}]
           } = Ash.load!(post, [:unfilterable_comments, :unsortable_comments, :secrets])
  end

  test "Post.create_for_owner requires a multi-word argument and sets the author from it" do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})

    post =
      Ash.create!(AshRpc.Test.Post, %{title: "p", owner_id: author.id}, action: :create_for_owner)

    assert post.author_id == author.id

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(AshRpc.Test.Post, %{title: "p"}, action: :create_for_owner)
  end

  test "Post.set_viewed sees its mapped argument under the internal name" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "p"})

    assert %{view_count: 1} = Ash.update!(post, %{is_viewed?: true}, action: :set_viewed)
    assert %{view_count: 0} = Ash.update!(post, %{is_viewed?: false}, action: :set_viewed)

    runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)
    assert %AshRpc.Entrypoint{action: :set_viewed} = runtime.entrypoints["set_post_viewed"]

    inputs =
      runtime
      |> AshRpc.Introspection.get_action!(AshRpc.Test.Post, :set_viewed)
      |> Map.fetch!(:inputs)
      |> Enum.map(& &1.name)

    assert :is_viewed? in inputs
    refute :audit_note in inputs
  end

  test "PostTag updates and destroys by its composite primary key" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "p"})
    tag = Ash.create!(AshRpc.Test.Tag, %{name: "t"})
    post_tag = Ash.create!(AshRpc.Test.PostTag, %{post_id: post.id, tag_id: tag.id})

    assert %{position: 2} = Ash.update!(post_tag, %{position: 2})
    assert :ok = Ash.destroy!(post_tag)
    assert [] = Ash.read!(AshRpc.Test.PostTag)
  end

  test "Post.title_shout loads into calculations, not a struct field" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "hi"})

    assert %{calculations: %{title_shout: "hi!"}} = Ash.load!(post, :title_shout)
    assert %{field?: false} = Ash.Resource.Info.calculation(AshRpc.Test.Post, :title_shout)
  end
end
