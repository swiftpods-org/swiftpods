class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-arm64.zip"
    sha256 "6a3259ef6b4edafbd0067779afa3697e05e0a35fc9f650ef130ce3a8587e33c1"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-x86_64.zip"
    sha256 "1cce967e1aa8897f17851364e393a57108cf9541ec1784ed52abacf5fda4217f"
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
