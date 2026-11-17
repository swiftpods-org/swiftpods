class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.16/swiftpods-0.3.16-macos-13.0-arm64.zip"
    sha256 "e7a01421fa26a2d9cdd0e821a237239e825d9e7ba9a2f6e43c52ff801c8e2145"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.16/swiftpods-0.3.16-macos-13.0-x86_64.zip"
    sha256 "916adce0f44fdcf6862ef604d3c465d25107c944cf25d3b1bc5b342d834dc38a"
  end
  version "0.3.16"
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
