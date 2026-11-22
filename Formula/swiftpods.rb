class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.18/swiftpods-0.3.18-macos-13.0-arm64.zip"
    sha256 "0c43fca7d09f2fa404505e611cbac1240c1f958d7d6a2fae9e6beae9c07bed1b"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.18/swiftpods-0.3.18-macos-13.0-x86_64.zip"
    sha256 "eb7801ac3ab377b725633c38c47dbb35be5e4dd662af4a686c53084909395462"
  end
  version "0.3.18"
  license "MIT"

  depends_on :macos

  def install
    minimum = { "arm64" => "13.0", "x86_64" => "13.0" }
    architecture = Hardware::CPU.arm? ? "arm64" : "x86_64"
    odie "No release for this architecture" unless minimum.key?(architecture)
    odie "Requires macOS #{minimum.fetch(architecture)} or newer" if MacOS.version < minimum.fetch(architecture)
    bin.install "bin/swiftpods"
    prefix.install "LICENSE", "README.md"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/swiftpods version").strip
  end
end
