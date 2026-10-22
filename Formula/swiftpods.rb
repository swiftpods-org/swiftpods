class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-arm64.zip"
    sha256 "726856b612f15fada84cbebb27abb46a77f222b28905c5df62f3be049055b4b2"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-x86_64.zip"
    sha256 "d5092a614745da35d45c206c56d4d74d19ea42ce026f66b5b97f1007595f1cb3"
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
