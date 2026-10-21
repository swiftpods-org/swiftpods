class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-arm64.zip"
    sha256 "63c010d6658de024d92ef56c7895b3bbebd22881ca11a7e04221477237d2c9d0"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-x86_64.zip"
    sha256 "778ed6e1275f2af7990cff2f432082afac1fdaa5622c3871932514359351caaa"
  end
  version "0.1.0"
  license "MIT"

  depends_on :macos
  depends_on "ruby"

  skip_clean "libexec"

  def install
    minimum = { "arm64" => "13.0", "x86_64" => "13.0" }
    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"
    odie "No release for this architecture" unless minimum.key?(architecture)
    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)
    libexec.install Dir["*"]
    # Prevent Homebrew from moving verified metafiles out of libexec.
    (prefix/"README.md").write (libexec/"README.md").read
    (prefix/"LICENSE").write (libexec/"LICENSE").read
    (bin/"swiftpods").write_env_script libexec/"bin/swiftpods",
      SWIFTPODS_RUBY: formula_opt_bin("ruby")/"ruby", SWIFTPODS_BUNDLE: libexec
    system bin/"swiftpods", "runtime", "verify", "--json"
  end

  test do
    assert_match "SwiftPods", shell_output("#{bin}/swiftpods --version")
    system bin/"swiftpods", "runtime", "verify", "--json"
  end
end
