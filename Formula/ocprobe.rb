class Ocprobe < Formula
  include Language::Python::Virtualenv

  desc "OpenCode Model Probe - Enterprise-grade model catalog lifecycle management"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v3.1.2/ocprobe-3.1.2.tar.gz"
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
    # Why virtualenv_create and not virtualenv_install_with_resources: the
    # latter ends with `venv.pip_install_and_link(buildpath)`, i.e. it pip
    # installs the formula's own source tree. This project is a bash tool with
    # one Python helper, not a Python distribution, so that step failed on every
    # single build.
    #
    # Why not venv.pip_install: it goes through std_pip_args, which carries
    # --no-deps --no-binary=:all:. --no-deps leaves jsonschema without attrs, so
    # `import jsonschema` raises on every config load; --no-binary forces
    # rpds-py to build from sdist, which needs a Rust toolchain. Wheels plus
    # normal dependency resolution is what works. --uploaded-prior-to is kept:
    # it is Homebrew's guard against a freshly compromised PyPI release, and
    # giving that up is not worth the convenience.
    #
    # And not venv.pip_install's own path to the venv's pip: the venv is created
    # --without-pip and Homebrew raises on without_pip: false for 3.12+. So pip
    # comes from the python@3.12 dependency, told which interpreter to install
    # into with --python=.
    virtualenv_create(libexec, "python3.12")

    python = formula_opt_bin("python@3.12")/"python3.12"
    system python, "-m", "pip", "--python=#{libexec}/bin/python", "install",
           "--only-binary=:all:", "--uploaded-prior-to=P1D",
           "pyyaml", "jsonschema"

    (libexec / "bin").install "bin/ocprobe"
    # Dir["lib/*"] deliberately: it takes EVERY file, not just *.sh.
    # lib/session_restore.py is a Python module loaded with importlib by
    # `ocprobe session restore`, and a *.sh glob would ship a tool whose
    # restore command dies with "no such file". Do not narrow this.
    (libexec / "lib/ocprobe").install Dir["lib/*"]
    (libexec / "share/ocprobe").install Dir["config/*"]
    # share/ocprobe is rooted at libexec, not the prefix, because the binary
    # resolves its own layout from the path it runs at: bin/ocprobe looks for
    # ../lib/ocprobe/*.sh and ../share/ocprobe/VERSION. libexec/bin/ocprobe
    # therefore needs libexec/share/ocprobe/VERSION. At the prefix it looks
    # right and is wrong, and every command dies reading a missing VERSION.
    (libexec / "share/ocprobe/VERSION").write version.to_s
    # The tarball ships docs/ocprobe.1.md; there is no docs/ocprobe.1. Homebrew
    # checks the formula's own file list against the archive, so naming a file
    # that is not there fails the build -- which is how this was found.
    man1.install "docs/ocprobe.1.md" => "ocprobe.1"

    (bin/"ocprobe").write <<~EOS
      #!/bin/bash
      export PATH="#{libexec}/bin:#{formula_opt_bin("curl")}:$PATH"
      exec "#{libexec}/bin/ocprobe" "$@"
    EOS
    (bin/"ocprobe").chmod 0755
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
    (testpath / "home/.config/ocprobe/config.yaml").delete if (testpath / "home/.config/ocprobe/config.yaml").exist?
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
    script = testpath / "dump.sql"
    script.write <<~SQL
      .mode insert session
      SELECT * FROM session;
      .mode insert message
      SELECT * FROM message;
    SQL
    dump = testpath / "good.sql"
    dump.write Utils.safe_popen_read("sqlite3", "-readonly", db.to_s, ".read #{script}")
    inreplace dump, /^INSERT INTO /, "INSERT OR REPLACE INTO "

    system bin / "ocprobe", "session", "restore", dump
    restored = shell_output("sqlite3 #{db} \"SELECT data FROM message WHERE id='m1';\"").strip
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
    evil_out = shell_output("#{bin}/ocprobe session restore #{evil} 2>&1", 1)
    refute_match "restored from", evil_out
    assert_equal (testpath / "before.db").binread, db.binread
    refute_match "should not appear",
                 shell_output("sqlite3 #{db} \"SELECT title FROM session WHERE id='s9';\" 2>/dev/null")
  end
end
