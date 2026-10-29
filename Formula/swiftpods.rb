class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-arm64.zip"
    sha256 "1723c9be8e5df399ccd077a8bc561413748ddb348188e9594af807ef1eb4a7d9"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/swiftpods-0.1.0-macos-13.0-x86_64.zip"
    sha256 "bd60020a9ad609f546f3c44a157e200f74e4b5dc24f530c2c6e7632d1d5bdd18"
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
