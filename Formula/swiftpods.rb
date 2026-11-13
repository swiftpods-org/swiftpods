class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.15/swiftpods-0.3.15-macos-13.0-arm64.zip"
    sha256 "d02079019ded4a6e764853070dc4c60d0de6b3d68a9dc7c14804d98101daab66"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.15/swiftpods-0.3.15-macos-13.0-x86_64.zip"
    sha256 "da12ad7fd08d58006595c5cb40fe39a112bbe5bd4be9fbedf8a79c0ae48c6826"
  end
  version "0.3.15"
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
