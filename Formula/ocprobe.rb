class Ocprobe < Formula
  include Language::Python::Virtualenv

  desc "OpenCode Model Probe - Enterprise-grade model catalog lifecycle management"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v3.1.2/ocprobe-3.1.2.tar.gz"
  version "3.1.2"
  sha256 "087bdcacd1e3ce5cb550c5c493875abdeb2bc7c541100df012c93fb54eb17fdb"
  license "MIT"

  depends_on "bash"
  depends_on "curl"
  depends_on "jq"
  depends_on "python@3.12"
  depends_on "sqlite"

  def install
    # Install to match binary's installed-mode bootstrap expectations:
    # binary at bin/ocprobe -> prefix/bin/ocprobe
    # lib/ -> prefix/lib/ocprobe/
    # config/ -> prefix/share/ocprobe/
    # VERSION -> prefix/share/ocprobe/VERSION
    #
    # The real binary goes to libexec, and bin/ocprobe becomes a small wrapper
    # that puts the Python environment on PATH first. See the wrapper below for
    # why that indirection is necessary rather than clever.
    # A venv built from the declared python@3.12, because the code needs an
    # interpreter that actually has PyYAML and jsonschema. See install_wrapper.
    #
    # FIRST, and not by accident: virtualenv_install_with_resources builds the
    # venv *at* libexec and clears it on the way. Anything installed under
    # libexec before this line is silently deleted -- which is exactly what
    # happened the first time this was written.
    virtualenv_install_with_resources
    (libexec / "requirements.txt").write "pyyaml\njsonschema\n"
    system libexec / "bin/pip", "install", "--requirement", libexec / "requirements.txt"

    (libexec / "bin").install "bin/ocprobe"
    # Dir["lib/*"] deliberately: it takes EVERY file, not just *.sh.
    # lib/session_restore.py is a Python module loaded with importlib by
    # `ocprobe session restore`, and a *.sh glob would ship a tool whose
    # restore command dies with "no such file". Do not narrow this.
    (libexec / "lib/ocprobe").install Dir["lib/*"]
    (prefix / "share/ocprobe").install Dir["config/*"]
    (prefix / "share/ocprobe/VERSION").write version.to_s
    man1.install "docs/ocprobe.1" => "ocprobe.1"
  end

  def caveats
    <<~EOS
      Configuration file: ~/.config/ocprobe/config.yaml
      Run `ocprobe config edit` to customize.

      State directory: ~/.local/state/ocprobe/

      To enable continuous monitoring:
        ocprobe scheduler install

      Requires OpenCode to be installed and authenticated.
    EOS
  end

  def install_wrapper
    # ocprobe is a bash program that shells out to `python3` (40 call sites) and
    # expects that python3 to be able to `import yaml, jsonschema` -- which
    # lib/config.sh does on every single config load. Two measured facts make
    # the python dependency insufficient on its own:
    #
    #   1. python@3.12 is versioned. `ls $(brew --prefix python@3.12)/bin` shows
    #      python3.12, pip3.12 and friends, and no bare `python3`; the
    #      unversioned one lives in its keg-only libexec/bin, which is
    #      deliberately not linked. A fresh macOS has no system python3 at all,
    #      so a bare `python3` can resolve to nothing.
    #   2. Neither PyYAML nor jsonschema is a Homebrew formula -- `brew info`
    #      finds neither -- because they are pip-only. No formula can provide
    #      them, so no dependency line can either.
    #
    # So the interpreter is built into a venv at install time, which puts a real
    # `python3` -- with both modules -- on PATH for the wrapper below.
    #
    # curl is keg-only too, and lib/db.sh calls it for the webhook alert, so its
    # bin goes on PATH for the same reason.
    venv = libexec
    curl_dir = formula_opt_bin("curl")
    <<~EOS
      #!/bin/bash
      export PATH="#{venv}/bin:#{curl_dir}:$PATH"
      exec "#{libexec}/bin/ocprobe" "$@"
    EOS
  end

  test do
    # Exercise the INSTALLED binary through the wrapper, with a throwaway HOME so
    # nothing reads or writes the real config or state.
    ENV["HOME"] = testpath / "home"
    (testpath / "home").mkpath

    version_out = shell_output("#{bin}/ocprobe version")
    assert_match "ocprobe #{version}", version_out

    # doctor must run: it loads every library, so it is the cheapest proof that
    # the wrapper's PATH is right.
    doctor = shell_output("#{bin}/ocprobe doctor 2>&1", 1)
    assert_match "ocprobe doctor", doctor

    # lib/session_restore.py must have shipped, and must be reachable from
    # lib/session.sh's own directory.
    assert_path_exists libexec / "lib/ocprobe/session_restore.py"
    assert_match "session_restore.py", (libexec / "lib/ocprobe/session.sh").read

    # A real restore, against a real database in the shape cmd_session_backup
    # dumps. This is the check that exists because a release once shipped
    # without session_restore.py and nothing noticed.
    db = testpath / "opencode.db"
    (testpath / "home/.config/ocprobe").mkpath
    (testpath / "home/.config/ocprobe/config.yaml").write <<~YAML
      version: 1
      opencode:
        config_path: "#{testpath}/opencode.json"
        db_path: "#{db}"
      logging:
        level: info
        format: text
        file_enabled: false
    YAML

    system "sqlite3", db, <<~SQL
      CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, data TEXT);
      CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, data TEXT);
      CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, data TEXT);
      CREATE TABLE todo(id TEXT PRIMARY KEY, session_id TEXT, content TEXT);
      INSERT INTO session VALUES('s1','t;1','multi' || char(10) || 'line');
      INSERT INTO message VALUES('m1','s1','has ; semicolon');
    SQL

    # Generated by `sqlite3 .mode insert`, exactly as cmd_session_backup does, so
    # the escaping is whatever this sqlite build actually emits rather than a
    # guess.
    dump = testpath / "good.sql"
    system "sqlite3", "-readonly", db, <<~SQL
      .mode insert session
      SELECT * FROM session;
      .mode insert message
      SELECT * FROM message;
    SQL
    inreplace dump, /^INSERT INTO / => "INSERT OR REPLACE INTO "
    (testpath / "good.sql").write dump.read

    system bin / "ocprobe", "session", "restore", dump
    restored = shell_output("sqlite3 #{db} \"SELECT data FROM message WHERE id='m1';\"")
    assert_equal "has ; semicolon", restored

    # A multi-statement bypass must be refused AND leave the database
    # byte-identical. Accepting the dump was the original bug; accepting it and
    # rolling back would still be a bug.
    (testpath / "before.db").write db.binread
    evil = testpath / "evil.sql"
    evil.write <<~SQL
      INSERT OR REPLACE INTO session VALUES('s9','should not appear','x');
      DELETE FROM message;
    SQL
    assert_failure system(bin / "ocprobe", "session", "restore", evil)
    assert_equal (testpath / "before.db").binread, db.binread
    refute_match "should not appear",
                 shell_output("sqlite3 #{db} \"SELECT title FROM session WHERE id='s9';\" 2>/dev/null")
  end
end
