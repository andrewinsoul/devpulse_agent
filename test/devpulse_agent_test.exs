defmodule DevpulseAgentTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias DevpulseAgent.{Config, Session, Workspace}

  defmodule RestartClient do
    def handshake(_base_url, _token, _attrs) do
      {:ok, %{session_id: "session-1", session_token: "session-token", expires_in: 3_600}}
    end

    def heartbeat(_base_url, _session_token, _attrs) do
      {:ok, %{ok: true}}
    end
  end

  setup do
    home_dir = Path.join(System.tmp_dir!(), "devpulse_home_#{System.unique_integer([:positive])}")
    File.rm_rf!(home_dir)
    File.mkdir_p!(home_dir)

    previous_home = System.get_env("HOME")
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("HOME")
        value -> System.put_env("HOME", value)
      end

      File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "config and session data round trip locally" do
    Config.save!(%{
      server_url: "http://example.test",
      master_api_token: "secret-token",
      default_team: "core",
      heartbeat_interval_ms: 1_000,
      offline_retention_ms: 5_000,
      log_level: "debug",
      workspace_mappings: [
        %{path: "/tmp/app", team_slug: "team-a", remote_url: "git@example.com:app.git"}
      ]
    })

    assert Config.load().server_url == "http://example.test"
    assert Config.load().master_api_token == "secret-token"
    assert Config.load().default_team == "core"
    assert Config.load().heartbeat_interval_ms == 1_000

    assert [%{path: "/tmp/app", team_slug: "team-a", remote_url: "git@example.com:app.git"}] =
             Config.load().workspace_mappings

    session = %Session{
      session_id: "session-1",
      session_token: "session-token",
      team_slug: "core",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      handshake_at: DateTime.utc_now(),
      hostname: "local-host",
      operating_system: "unix/linux",
      hardware_fingerprint: "fingerprint",
      server_url: "http://example.test"
    }

    Session.save!(session)

    loaded = Session.load()
    assert loaded.session_id == "session-1"
    assert loaded.session_token == "session-token"
    assert loaded.team_slug == "core"
    assert loaded.server_url == "http://example.test"
    refute Session.expired?(loaded)
  end

  test "workspace team linking is persisted locally and rejects mismatches" do
    repo = Path.join(System.tmp_dir!(), "devpulse_repo_#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

    Workspace.select_team!(repo, "team-alpha", "git@example.com:app.git")

    assert {:ok, "team-alpha", :local_config} = Workspace.resolve_team(repo, [], Config.load())

    assert {:ok, "team-alpha", :explicit} =
             Workspace.resolve_team(repo, [team: "team-alpha"], Config.load())

    assert {:error, {:workspace_team_conflict, "team-alpha", "team-beta"}} =
             Workspace.resolve_team(repo, [team: "team-beta"], Config.load())
  end

  test "team link command stores the team in the workspace" do
    repo = Path.join(System.tmp_dir!(), "devpulse_repo_#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

    output =
      capture_io(fn ->
        DevpulseAgent.CLI.main([
          "team",
          "link",
          "team-alpha",
          "--workspace",
          repo
        ])
      end)

    assert output =~ "Linked team team-alpha to #{repo}"
    assert {:ok, "team-alpha", :local_config} = Workspace.resolve_team(repo, [], Config.load())
  end

  test "team link refuses to override an existing different team" do
    repo = Path.join(System.tmp_dir!(), "devpulse_repo_#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

    assert {:ok, :linked, _path} = Workspace.link_team(repo, "team-alpha", "git@example.com:app.git")

    assert {:error, {:workspace_team_conflict, "team-alpha", "team-beta"}} =
             DevpulseAgent.CLI.main([
               "team",
               "link",
               "team-beta",
               "--workspace",
               repo
             ])
  end

  test "team link requires a git repo" do
    repo = Path.join(System.tmp_dir!(), "devpulse_repo_#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    assert {:error, {:not_git_repo, ^repo}} =
             DevpulseAgent.CLI.main([
               "team",
               "link",
               "team-alpha",
               "--workspace",
               repo
             ])
  end

  test "the supervised agent restarts after an unexpected crash" do
    repo = Path.join(System.tmp_dir!(), "devpulse_repo_#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    assert {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

    config = %{
      server_url: "http://example.test",
      master_api_token: "token",
      default_team: nil,
      heartbeat_interval_ms: 60_000,
      offline_retention_ms: 60_000,
      log_level: "info",
      workspace_mappings: []
    }

    {:ok, sup_pid} =
      DevpulseAgent.RunnerSupervisor.start_link(
        workspace: repo,
        team: "team-alpha",
        client: RestartClient,
        config: config
      )

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        Process.exit(sup_pid, :shutdown)
      end
    end)

    first_pid = Process.whereis(DevpulseAgent.Agent)
    assert is_pid(first_pid)

    Process.exit(first_pid, :kill)

    new_pid =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        Process.sleep(50)
        pid = Process.whereis(DevpulseAgent.Agent)

        cond do
          is_pid(pid) and pid != first_pid ->
            {:halt, pid}

          true ->
            {:cont, nil}
        end
      end)

    assert is_pid(new_pid)
    assert new_pid != first_pid
    assert Process.alive?(new_pid)
  end
end
