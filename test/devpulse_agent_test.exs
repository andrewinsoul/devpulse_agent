defmodule DevpulseAgentTest do
  use ExUnit.Case
  alias DevpulseAgent.{Agent, Buffer, Config, Git, Lifecycle, Session, Workspace}

  defmodule TestGit do
    def metadata(_path) do
      {:ok,
       %{
         project_name: "devpulse-repo",
         repo_path: "/tmp/devpulse-repo",
         branch: "main",
         remote_url: "https://github.com/example/devpulse-repo.git",
         has_uncommitted_changes: false
       }}
    end
  end

  defmodule ReauthClient do
    def handshake(_base_url, token, attrs) do
      send_observer({:handshake, token, attrs})

      {:ok,
       %{
         "session" => %{
           "session_id" => "session-#{Process.get(:handshake_count, 0) + 1}",
           "session_token" => "session-token",
           "expires_in" => 3_600
         }
       }}
    end

    def heartbeat(_base_url, session_token, attrs) do
      count = Process.get(:heartbeat_count, 0) + 1
      Process.put(:heartbeat_count, count)
      send_observer({:heartbeat, session_token, attrs})

      if count == 1 do
        {:error, :unauthorized}
      else
        {:ok, %{"ok" => true}}
      end
    end

    defp send_observer(message) do
      send(Process.whereis(:devpulse_test_observer), message)
    end
  end

  setup do
    home_dir = Path.join(System.tmp_dir!(), "devpulse_home_#{System.unique_integer([:positive])}")

    workspace =
      Path.join(System.tmp_dir!(), "devpulse_workspace_#{System.unique_integer([:positive])}")

    File.rm_rf!(home_dir)
    File.rm_rf!(workspace)
    File.mkdir_p!(home_dir)
    File.mkdir_p!(workspace)

    previous_home = System.get_env("HOME")
    previous_config_dir = Application.get_env(:devpulse_agent, :config_dir)
    System.put_env("HOME", home_dir)
    Application.put_env(:devpulse_agent, :config_dir, home_dir)
    Process.register(self(), :devpulse_test_observer)

    on_exit(fn ->
      if Process.whereis(:devpulse_test_observer) == self() do
        Process.unregister(:devpulse_test_observer)
      end

      case previous_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      case previous_config_dir do
        nil -> Application.delete_env(:devpulse_agent, :config_dir)
        value -> Application.put_env(:devpulse_agent, :config_dir, value)
      end

      File.rm_rf!(home_dir)
      File.rm_rf!(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "configuration and workspace mappings round trip with the current schema", %{
    workspace: workspace
  } do
    Config.save!(%{
      server_url: "http://example.test/api/v1",
      token: "pat-token",
      default_team: "core",
      heartbeat_interval_ms: 1_000,
      offline_retention_ms: 5_000,
      log_level: "debug",
      workspace_mappings: [
        %{
          path: workspace,
          team_slug: "team-a",
          project_slug: "project-a",
          remote_url: "git@example.com:app.git"
        }
      ]
    })

    config = Config.load()

    assert config.server_url == "http://example.test/api/v1"
    assert config.token == "pat-token"
    assert config.default_team == "core"
    assert config.heartbeat_interval_ms == 1_000

    assert [
             %{
               path: ^workspace,
               team_slug: "team-a",
               project_slug: "project-a",
               remote_url: "git@example.com:app.git"
             }
           ] = config.workspace_mappings
  end

  test "pending invite assignment round trips through secure global state" do
    assignment = %{
      "team" => %{
        "id" => "team-1",
        "name" => "Core",
        "slug" => "core"
      },
      "project" => %{
        "id" => "project-1",
        "name" => "DevPulse",
        "git_remote_url" => "git@example.com:devpulse.git"
      },
      "assignment" => %{
        "invite_id" => "invite-1",
        "team_id" => "team-1",
        "project_id" => "project-1"
      }
    }

    Config.save_pending_assignment!(assignment)

    assert Config.load_pending_assignment() == assignment
    assert Bitwise.band(File.stat!(Config.pending_assignment_file()).mode, 0o077) == 0

    Config.clear_pending_assignment!()
    assert Config.load_pending_assignment() == nil
  end

  test "workspace project configuration resolves the project assigned during init", %{
    workspace: workspace
  } do
    assert {:ok, _path} =
             Config.save_workspace_config(workspace, %{
               workspace_path: workspace,
               team: %{"id" => "team-1", "name" => "Core", "slug" => "core"},
               project: %{
                 "id" => "project-1",
                 "name" => "DevPulse",
                 "git_remote_url" => "git@example.com:devpulse.git"
               }
             })

    assert {:ok, %{project_id: "project-1", project_name: "DevPulse"}} =
             Workspace.resolve_project(workspace)

    metadata = %{
      remote_url: "git@example.com:devpulse.git",
      repo_path: workspace
    }

    assert {:ok, "core", :local_config} =
             Workspace.resolve_team(workspace, metadata, [], Config.default_config())
  end

  test "session credentials are persisted and sessions without expiry are invalid" do
    session = %Session{
      session_id: "session-1",
      session_token: "session-token",
      team_slug: "core",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      handshake_at: DateTime.utc_now(),
      hostname: "local-host",
      operating_system: "unix/linux",
      hardware_fingerprint: "fingerprint",
      server_url: "http://example.test/api/v1"
    }

    Session.save!(session)

    loaded = Session.load()
    assert loaded.session_id == "session-1"
    assert loaded.session_token == "session-token"
    refute Session.expired?(loaded)

    assert Session.expired?(%Session{session_id: "missing-expiry"})
  end

  test "workspace and project sessions are isolated", %{workspace: workspace} do
    first_file = Config.state_file(workspace, "project-1", "session.json")
    second_file = Config.state_file(workspace, "project-2", "session.json")

    first = %Session{
      session_id: "session-1",
      session_token: "token-1",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    second = %Session{
      session_id: "session-2",
      session_token: "token-2",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    Session.save!(first, first_file)
    Session.save!(second, second_file)

    assert Session.load(first_file).session_token == "token-1"
    assert Session.load(second_file).session_token == "token-2"
  end

  test "Git remote matching accepts HTTPS and SSH forms" do
    assert Git.remote_matches?(
             "https://github.com/acme/devpulse.git",
             "git@github.com:acme/devpulse.git"
           )

    refute Git.remote_matches?(
             "https://github.com/acme/devpulse.git",
             "git@github.com:acme/other-repo.git"
           )
  end

  test "buffer limits retain the newest events" do
    events =
      Enum.map(1..5, fn number ->
        %{"event_id" => Integer.to_string(number), "captured_at" => "2026-09-24T12:00:00Z"}
      end)

    {bounded, dropped} = Buffer.bound(events, 3, 10_000)

    assert Enum.map(bounded, & &1["event_id"]) == ["3", "4", "5"]
    assert dropped == 2
  end

  test "agent lifecycle prevents duplicate instances and releases its lock", %{
    workspace: workspace
  } do
    assert {:ok, lock_file} = Lifecycle.acquire(workspace, "project-1")
    assert {:running, _pid} = Lifecycle.status(lock_file)
    assert {:error, :already_running} = Lifecycle.acquire(workspace, "project-1")

    assert :ok = Lifecycle.release(lock_file)
    assert Lifecycle.status(lock_file) == :not_running
    assert {:ok, second_lock_file} = Lifecycle.acquire(workspace, "project-1")
    assert :ok = Lifecycle.release(second_lock_file)
  end

  test "corrupt session state is quarantined instead of crashing" do
    File.mkdir_p!(Config.config_dir())
    File.write!(Config.session_file(), "{not-json")

    assert Session.load() == nil
    assert not File.exists?(Config.session_file())
    assert Path.wildcard(Config.session_file() <> ".corrupt-*") != []
  end

  test "malformed buffered events are quarantined while valid events survive" do
    File.mkdir_p!(Config.config_dir())
    buffer_file = Config.buffer_file()
    File.write!(buffer_file, Jason.encode!(%{"event_id" => "valid"}) <> "\\nnot-json\\n")

    assert [%{"event_id" => "valid"}] = Buffer.load(buffer_file)
    assert not File.exists?(buffer_file)
    assert Path.wildcard(buffer_file <> ".corrupt-*") != []
  end

  test "heartbeat uses the session token and re-handshakes once after unauthorized", %{
    workspace: workspace
  } do
    assert {:ok, _path} =
             Config.save_workspace_config(workspace, %{
               workspace_path: workspace,
               team: %{"id" => "team-1", "name" => "Core", "slug" => "core"},
               project: %{
                 "id" => "project-1",
                 "name" => "DevPulse",
                 "git_remote_url" => "git@example.com:devpulse.git"
               }
             })

    config = %{
      server_url: "http://example.test/api/v1",
      token: "pat-token",
      default_team: nil,
      heartbeat_interval_ms: 60_000,
      offline_retention_ms: 60_000,
      log_level: "info",
      workspace_mappings: []
    }

    {:ok, agent_pid} =
      Agent.start_link(
        workspace: workspace,
        team: "core",
        client: ReauthClient,
        git: TestGit,
        config: config
      )

    on_exit(fn ->
      if Process.alive?(agent_pid) do
        GenServer.stop(agent_pid, :normal)
      end
    end)

    assert_receive {:handshake, "pat-token", _context}, 1_000
    assert_receive {:heartbeat, "session-token", first_event}, 1_000
    assert first_event.project_id == "project-1"
    assert is_binary(first_event.event_id)

    assert_receive {:handshake, "pat-token", _context}, 1_000
    assert_receive {:heartbeat, "session-token", second_event}, 1_000
    assert second_event.project_id == "project-1"
    assert second_event.event_id == first_event.event_id
  end
end