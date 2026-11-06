class Swiftpods < Formula
  desc "Dependency manager for Apple platform projects"
  homepage "https://swiftpods.org"
  if Hardware::CPU.arm?
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.14/swiftpods-0.3.14-macos-13.0-arm64.zip"
    sha256 "2f157f30f5322f840b9786c949bb456f9107d4ef87045213fccb253c57adedc8"
  else
    url "https://github.com/swiftpods-org/swiftpods/releases/download/v0.3.14/swiftpods-0.3.14-macos-13.0-x86_64.zip"
    sha256 "9ca965617c8da85c8a1663dc3969a186f85a3c2168930fa9dbccf0563c56994f"
  end
  version "0.3.14"
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
