class Ocprobe < Formula
  desc "OpenCode Model Probe - Enterprise-grade model catalog lifecycle management"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v3.0.3/ocprobe-3.0.3.tar.gz"
  sha256 "cb2b312d3eb936115b376cbae885372f2da02995be9443614fdb367992bb7034"
  license "MIT"
  version "3.0.3"

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
