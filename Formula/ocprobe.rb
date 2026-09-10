class Ocprobe < Formula
  desc "OpenCode Model Probe - Enterprise-grade model catalog lifecycle management"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v3.1.0/ocprobe-3.1.0.tar.gz"
  sha256 "884fa92e6bed6c8a971df63a082a080b798b8d16e13309103756a3b9ad0647a5"
  license "MIT"
  version "3.1.0"

  depends_on "bash"
  depends_on "jq"
  depends_on "python@3.12"
  depends_on "sqlite"

  def install
    # Install to match binary's installed-mode bootstrap expectations:
    # binary at bin/ocprobe -> prefix/bin/ocprobe
    # lib/ -> prefix/lib/ocprobe/
    # config/ -> prefix/share/ocprobe/
    # VERSION -> prefix/share/ocprobe/VERSION
    (prefix/"bin").install "bin/ocprobe"
    (prefix/"lib/ocprobe").install Dir["lib/*"]
    (prefix/"share/ocprobe").install Dir["config/*"]
    (prefix/"share/ocprobe/VERSION").write version.to_s
    # Install man page
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

  test do
    assert_match "ocprobe #{version}", shell_output("#{bin}/ocprobe version")
    assert_match "audit", shell_output("#{bin}/ocprobe help")
  end
end
